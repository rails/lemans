# frozen_string_literal: true

require "daytona"
require "faraday"
require "faraday/multipart"
require "json"

module Lemans
  module Environments
    class Daytona
      # Reroutes the SDK's streaming file transfers from typhoeus/libcurl to
      # Faraday over Net::HTTP: pure-Ruby I/O is immune to the libcurl GC race
      # that segfaults the VM under concurrent transfers.
      # Only the FileTransfer entry points move — the generated JSON clients
      # stay on typhoeus. Opt-in via .apply!
      module FaradayTransfer
        def self.apply!
          ::Daytona::FileTransfer.singleton_class.prepend(Transfers)
        end

        # The prepend seam over ::Daytona::FileTransfer's entry points.
        module Transfers
          def stream_download(api_client:, remote_path:, timeout:, on_progress: nil, cancel_event: nil, &)
            FaradayTransfer.download(api_client:, remote_path:, timeout:, on_progress:, cancel_event:, &)
          end

          def stream_upload(api_client:, remote_path:, source:, timeout:, on_progress: nil, cancel_event: nil)
            FaradayTransfer.upload(api_client:, remote_path:, source:, timeout:, on_progress:, cancel_event:)
          end
        end

        # Counts bytes as multipart-post drains the file and surfaces
        # cancellation as an exception, which tears the connection down.
        class UploadIO
          def initialize(io, remote_path, on_progress:, cancel_event:)
            @io = io
            @remote_path = remote_path
            @on_progress = on_progress
            @cancel_event = cancel_event
            @bytes_sent = 0
          end

          def read(...)
            raise ::Daytona::Sdk::Error, "Upload cancelled: #{@remote_path}" if @cancel_event&.set?

            chunk = @io.read(...)
            if chunk && @on_progress
              @bytes_sent += chunk.bytesize
              @on_progress.call(::Daytona::UploadProgress.new(bytes_sent: @bytes_sent))
            end
            chunk
          end

          def size = @io.size
          def length = @io.size
          def rewind = @io.rewind
          def eof? = @io.eof?
          def close = @io.close
        end

        class << self
          def download(api_client:, remote_path:, timeout:, on_progress:, cancel_event:, &block)
            parser = nil
            bytes_received = 0
            sink = proc do |chunk|
              raise ::Daytona::Sdk::Error, "Download cancelled: #{remote_path}" if cancel_event&.set?

              if on_progress
                bytes_received += chunk.bytesize
                on_progress.call(::Daytona::DownloadProgress.new(bytes_received:, total_bytes: parser&.part_total_bytes))
              end
              block.call(chunk)
            end
            parser = ::Daytona::MultipartDownloadStreamParser.new(&sink)

            error_body = String.new.b
            response = perform_download(api_client, remote_path, timeout, parser, error_body, cancel_event)

            raise ::Daytona::Sdk::Error, "Download cancelled: #{remote_path}" if cancel_event&.set?
            raise ::Daytona::Sdk::Error, parser.error_message if parser.error_message
            raise ::Daytona::Sdk::Error, "HTTP #{response.status}: #{error_body}" unless response.success?

            parser.finish!
            ::Daytona::FileTransfer.assert_download_length!(parser, remote_path)
            nil
          rescue Faraday::TimeoutError
            raise ::Daytona::Sdk::Error, "Download timed out: #{remote_path}"
          rescue Faraday::Error => e
            raise ::Daytona::Sdk::Error, "Download failed for #{remote_path}: #{e.message}"
          end

          def upload(api_client:, remote_path:, source:, timeout:, on_progress:, cancel_event:)
            ::Daytona::FileTransfer.with_upload_file(source, cancel_event, remote_path) do |upload_path|
              expected_bytes = File.size(upload_path)
              response = File.open(upload_path, "rb") do |file|
                io = UploadIO.new(file, remote_path, on_progress:, cancel_event:)
                perform_upload(api_client, remote_path, timeout, io)
              end
              raise ::Daytona::Sdk::Error, "HTTP #{response.status}: #{response.body}" unless response.success?

              verify_upload(response.body, remote_path, expected_bytes)
            end
          rescue Faraday::TimeoutError
            raise ::Daytona::Sdk::Error, "Upload timed out: #{remote_path}"
          rescue Faraday::Error => e
            raise ::Daytona::Sdk::Error, "Upload failed for #{remote_path}: #{e.message}"
          end

          private

          def perform_download(api_client, remote_path, timeout, parser, error_body, cancel_event)
            boundary_known = false
            connection(api_client.config).post("#{api_client.config.base_url}/files/bulk-download") do |req|
              req.headers.update(api_client.default_headers)
              req.headers["Accept"] = "multipart/form-data"
              req.headers["Content-Type"] = "application/json"
              req.body = JSON.generate(paths: [remote_path])
              apply_timeout(req, timeout)
              req.options.on_data = proc do |chunk, _received, env|
                raise ::Daytona::Sdk::Error, "Download cancelled: #{remote_path}" if cancel_event&.set?

                if (200..299).cover?(env.status)
                  unless boundary_known
                    ::Daytona::FileTransfer.assign_download_boundary(parser, env.response_headers["content-type"])
                    boundary_known = true
                  end
                  parser << chunk
                else
                  error_body << chunk.b
                end
              end
            end
          end

          def perform_upload(api_client, remote_path, timeout, io)
            connection(api_client.config, multipart: true).post("#{api_client.config.base_url}/files/bulk-upload") do |req|
              req.headers.update(api_client.default_headers)
              # The multipart middleware supplies its own boundary-bearing type.
              req.headers.delete("Content-Type")
              apply_timeout(req, timeout)
              req.body = {
                "files[0].path" => remote_path,
                "files[0].file" => Faraday::Multipart::FilePart.new(io, "application/octet-stream", File.basename(remote_path))
              }
            end
          end

          def verify_upload(body, remote_path, expected_bytes)
            recorded = ::Daytona::FileTransfer.recorded_upload_bytes(body, remote_path)
            return if recorded.nil? || recorded == expected_bytes

            raise ::Daytona::Sdk::Error,
                  "Upload size mismatch for #{remote_path}: sent #{expected_bytes} bytes, daemon recorded #{recorded}"
          end

          def connection(config, multipart: false)
            Faraday.new(ssl: { verify: config.verify_ssl, verify_hostname: config.verify_ssl_host }) do |f|
              f.request :multipart if multipart
              f.adapter :net_http
            end
          end

          # Typhoeus treats 0 as "no deadline"; Faraday has no such switch, so
          # 0 falls back to Net::HTTP's per-read defaults instead.
          def apply_timeout(req, timeout)
            req.options.timeout = timeout if timeout&.positive?
          end
        end
      end
    end
  end
end
