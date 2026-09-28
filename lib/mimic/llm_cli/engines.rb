require_relative "base"
require_relative "../engine_cli"
require_relative "../result"

module Mimic
  module LlmCli
    # `llm engines` -- installed engine details and the update pass.
    class Engines < Base
      default_command :list

      desc "list", "list all engines and their local source and binary details"
      def list
        active = LlmConfig.load.llama.engine if LlmConfig.exists?
        EngineCli::Registry.names.each do |name|
          registry = EngineCli::Registry
          source = EngineCli::Source.local_status(name)
          binary = registry.binaries(name).find { |path| path && File.file?(path) }

          puts "#{name}#{' (active)' if name == active}"
          puts "  Source:   #{registry.url(name)}"
          puts "  Branch:   #{registry.branch(name)}"
          puts "  Checkout: #{registry.repo(name)}"
          puts "  Revision: #{source ? "#{source[:commit]} (#{source[:dirty] ? 'dirty' : 'clean'})" : 'not checked out'}"
          puts "  Binary:   #{binary || 'missing'}"
          puts
        end
      end

      desc "update", "fetch and rebuild outdated llama.cpp, ik_llama.cpp, and Prism engines"
      method_option :rollback, type: :string, enum: EngineCli::Registry.names,
                               desc: "rebuild an engine at its last-good commit"
      def update
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
