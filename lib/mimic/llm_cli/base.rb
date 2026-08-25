require_relative "../ui"
require "thor"

module Mimic
  module LlmCli
    # Abstract parent for every `llm` command class. It declares no commands
    # of its own -- a public instance method here would become a Thor task on
    # all of them -- only the colour/prompt handles and the one way this CLI
    # reports a Result.
    class Base < Thor
      def self.exit_on_failure? = true

      def initialize(*args)
        super
        @prompt = Ui::Prompt.new
      end

      private

      def report(result)
        puts result.ok? ? Ui.green(result.message) : Ui.red(result.message)
        raise SystemExit, 1 unless result.ok?
      end
    end
  end
end
