require_relative "../util/probes"

module Mimic
  module Engine
    # llama.cpp's router mode, seen from outside: which model children it is
    # running, whether one is mid-request, and asking it to drop one. Unloading
    # frees the child's VRAM while the router keeps the port, and the router
    # loads the model again on the next request that names it.
    class Router
      RUNNING = %w[loaded loading sleeping].freeze

      Child = Data.define(:id, :port)

      def initialize(base_url)
        @base_url = base_url
      end

      # nil when the router does not answer, so "nothing loaded" and "no
      # server" stay two different answers.
      def running
        data = Util::Probes.http_json("#{@base_url}/models", timeout: 3)
        return nil if data.nil?

        (data["data"] || []).filter_map do |entry|
          next unless RUNNING.include?(entry.dig("status", "value"))

          Child.new(entry["id"], child_port(entry.dig("status", "args") || []))
        end
      end

      def busy?(child)
        slots = Util::Probes.http_json("http://127.0.0.1:#{child.port}/slots", timeout: 3)
        Array(slots).any? { |slot| slot["is_processing"] }
      end

      def unload(id)
        Util::Probes.post("#{@base_url}/models/unload", { "model" => id }).is_a?(Net::HTTPSuccess)
      end

      # The router answers the unload at once and stops the child afterwards
      # (a forced kill comes 10 s later), so the VRAM is only free once the
      # child has left its list.
      def wait_stopped(ids, attempts: 30)
        Util::Probes.wait_until(attempts: attempts, delay: 1, label: "waiting for the model to unload") do
          (running || []).none? { |child| ids.include?(child.id) }
        end
      end

      private

      def child_port(args)
        flag = args.index("--port")
        flag && Integer(args[flag + 1], exception: false)
      end
    end
  end
end
