require "open3"

module Mimic
  module EngineCli
    # The long options one llama-server build actually carries, read from its
    # own --completion-bash.
    #
    # The router rejects the whole preset file over a single key its arg table
    # does not know ("option 'reasoning-effort' not recognized in preset"), and
    # a fork can be months behind mainline's flag surface. Audit the preset
    # against the binary that will read it, not mainline's current flag list.
    #
    # --help is not the source: its flag column wraps and its descriptions
    # name other flags, so both directions of that parse are wrong.
    class BinaryOptions
      # set_preset_only() options are router-mode preset keys with no CLI
      # form, so no completion list ever mentions them.
      PRESET_ONLY = %w[load-on-startup stop-timeout dedup-cache-models].freeze

      def initialize(binary)
        @binary = binary.to_s
      end

      # A build that answers nothing is not evidence against a key -- an
      # unreadable flag list disables the audit rather than emptying the
      # preset.
      def supports?(name) = names.empty? || PRESET_ONLY.include?(name) || names.include?(name)

      def names = @names ||= parse(completion_script)

      private

      def completion_script
        out, = Open3.capture2e(@binary, "--completion-bash")
        out
      rescue SystemCallError
        ""
      end

      def parse(script)
        opts = script[/opts="([^"]*)"/, 1] || ""
        opts.split.grep(/\A--/).map { |flag| flag.delete_prefix("--") }
      end
    end
  end
end
