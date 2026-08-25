require_relative "client/hermes"
require_relative "client/goose"
require_relative "client/crush"
require_relative "client/opencode"
require_relative "client/pi"

module Mimic
  module Client
    # Every agent that reads the LLM config, in sync order. Single source for
    # both the sync loop and the `llm sync` help text, so the two cannot drift
    # apart.
    ROSTER = [Hermes, Goose, Crush, Opencode, Pi].freeze
    CLIENTS = ROSTER.map { |client| client.name.split("::").last.downcase }.freeze

    def self.sync(settings)
      ROSTER.map { |client| client.new(settings) }.select(&:sync).map(&:name)
    end
  end
end
