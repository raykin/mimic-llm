require_relative "base"
require_relative "../engine_cli"
require_relative "../result"

module Mimic
  module LlmCli
    # `llm update` -- how far behind upstream each engine checkout is.
    class Update < Base
      desc "engines", "check llama.cpp/ik_llama.cpp updates and rebuild"
      method_option :rollback, type: :string, enum: EngineCli::Registry.names,
                               desc: "rebuild an engine at its last-good commit"
      def engines
        updater = EngineCli::Update.new
        if options[:rollback]
          failure = updater.rollback(options[:rollback])
          report(failure) if failure
          return
        end

        updater.run
      end
    end
  end
end
