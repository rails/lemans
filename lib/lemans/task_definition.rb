# frozen_string_literal: true

module Lemans
  # A single task definition
  class TaskDefinition
    attr_reader :name

    attr_accessor :difficulty, :tags, :description

    private attr_reader :config

    def initialize(config, name)
      @config = config
      @name = name
      @difficulty = :easy
      @tags = []
      @description = ""
    end

    def digest
      @digest ||= begin
        # TODO: implement me
      end
    end
  end
end
