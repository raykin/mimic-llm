require "json"
require "pathname"
require_relative "../paths"
require_relative "../util/probes"

module Mimic
  module Agent
    # Muse fetches `<origin>/muse-code/models` before its first inference call,
    # reusing only the scheme, host and port of the configured base URL, and
    # refuses to start without a catalog. llama-server does not serve that
    # route, so the undocumented `model_catalog` key in settings.json is the
    # only way to satisfy it without standing a second endpoint up.
    #
    # `endpoint_transport` is one global provider switch rather than an
    # additive list, so writing it into ~/.config/muse/settings.json would
    # repoint the user's whole muse install. mimic keeps its own config root
    # and hands it over as XDG_CONFIG_HOME instead.
    class Muse
      INSTALL_HINT = "curl -fsSL https://dev.meta.ai/install.sh | bash"

      # Muse drops every catalog row whose provider and profile disagree with
      # the session's; "tbh" is the profile its sessions run under.
      PROVIDER_ID = "meta"
      PROFILE_ID = "tbh"

      FALLBACK_OUTPUT_LIMIT = 32_768

      def initialize(settings)
        @settings = settings
      end

      def launch(extra_args)
        abort "muse binary not found -- install it with `#{INSTALL_HINT}`" if Util::Probes.which("muse").nil?

        base = base_url
        model = @settings.model.name
        write_settings(base, model)
        puts "mimic ready at #{base} · model #{model}"
        code = Agent.spawn_and_wait(["muse", *extra_args], { "XDG_CONFIG_HOME" => home.to_s })
        raise SystemExit, code if code&.nonzero?
      end

      private

      def base_url = "#{@settings.llama.base_url}/v1"

      def home = Paths::AGENTS_DIR / "muse"

      def settings_path = home / "muse/settings.json"

      def user_settings_path
        root = ENV["XDG_CONFIG_HOME"].to_s.strip
        root = "#{Dir.home}/.config" if root.empty?
        Pathname.new(root) / "muse/settings.json"
      end

      # Muse persists its own settings back into whichever config root it was
      # given, so once mimic's file exists it is the base and everything muse
      # recorded there survives. Before that the user's own file seeds it, so a
      # first launch keeps their skills, hooks, MCP servers and TUI settings.
      def base_settings
        [settings_path, user_settings_path].each do |path|
          next unless path.file?

          return JSON.parse(path.read)
        rescue JSON::ParserError
          raise if path == settings_path

          next
        end
        {}
      end

      def write_settings(base, model)
        settings = base_settings
        settings["schema_version"] ||= 1
        settings["provider"] = PROVIDER_ID
        settings["model"] = model
        # llama-server wants no credential, and muse refuses to start on the
        # default "bearer" unless one is configured.
        settings["endpoint_transport"] = { "base_url" => base, "auth" => "none" }
        settings["model_catalog"] = [catalog_row(model)]

        settings_path.dirname.mkpath
        text = "#{JSON.pretty_generate(settings)}\n"
        settings_path.write(text) if !settings_path.exist? || settings_path.read != text
      end

      def catalog_row(model)
        context = @settings.model.context_length.to_i
        {
          "model_id" => model,
          "provider_id" => PROVIDER_ID,
          "profile_id" => PROFILE_ID,
          "display_label" => model,
          "visibility" => "visible",
          "display_order" => 0,
          "is_default" => true,
          "context_limit" => context,
          "output_limit" => [context, FALLBACK_OUTPUT_LIMIT].min,
          "description" => "Served by llama.cpp",
        }
      end
    end
  end
end
