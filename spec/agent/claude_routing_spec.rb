require_relative "../../lib/mimic"
require_relative "../../lib/mimic/agent"
require "json"
require "open3"
require "socket"
require "timeout"
require "tmpdir"

# Runs the real `claude -p` the way `mimic claude` launches it, against a fake
# llama-server on a free port, and checks every request Claude sends lands
# there -- even with an OAuth login in ~/.claude/.credentials.json and with
# both the environment and a forwarded --settings pointing ANTHROPIC_BASE_URL
# at a decoy server.
RSpec.describe Mimic::Agent::Claude do
  class FakeLlamaServer
    REPLY = "pong from fake llama".freeze
    MESSAGES = %r{\APOST /v1/messages[ ?]}

    attr_reader :requests

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @requests = Queue.new
      @thread = Thread.new { loop { serve(@server.accept) } }
    end

    def port = @server.addr[1]

    def stop
      @thread.kill
      @server.close
    end

    private

    def serve(client)
      request_line = client.gets.to_s.strip
      headers = {}
      while (line = client.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      body = client.read(headers.fetch("content-length", "0").to_i).to_s
      @requests << { line: request_line, headers: headers, body: body }
      respond(client, request_line, body)
    rescue IOError, SystemCallError
      nil
    ensure
      client.close
    end

    def respond(client, request_line, body)
      unless request_line.match?(MESSAGES)
        return write(client, "404 Not Found", "application/json", "{}")
      end

      payload = JSON.parse(body)
      if payload["stream"]
        write(client, "200 OK", "text/event-stream", sse(payload["model"]))
      else
        write(client, "200 OK", "application/json", JSON.generate(message(payload["model"], REPLY)))
      end
    end

    def write(client, status, type, body)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: close\r\n\r\n#{body}")
    end

    def message(model, text)
      {
        id: "msg_fake", type: "message", role: "assistant", model: model,
        content: text ? [{ type: "text", text: text }] : [],
        stop_reason: text ? "end_turn" : nil, stop_sequence: nil,
        usage: { input_tokens: 1, output_tokens: 1 },
      }
    end

    def sse(model)
      [
        [:message_start, { type: "message_start", message: message(model, nil) }],
        [:content_block_start, { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
        [:content_block_delta, { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: REPLY } }],
        [:content_block_stop, { type: "content_block_stop", index: 0 }],
        [:message_delta, { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: nil },
                           usage: { output_tokens: 1 } }],
        [:message_stop, { type: "message_stop" }],
      ].map { |event, data| "event: #{event}\ndata: #{JSON.generate(data)}\n\n" }.join
    end
  end

  # A named pipe in place of the file: opening its write end blocks until a
  # reader opens the other end, so the open returning means a read attempt.
  class ReadDetector
    def initialize(path, content)
      File.mkfifo(path)
      @opened = false
      @thread = Thread.new do
        loop do
          File.open(path, "w") { |pipe| pipe.write(content) }
          @opened = true
        end
      end
    end

    def opened? = @opened

    def stop
      @thread.kill.join(1)
    end
  end

  OAUTH_LOGIN = JSON.generate(
    claudeAiOauth: { accessToken: "sk-ant-oat01-fake-login", refreshToken: "fake-refresh",
                     expiresAt: 4_102_444_800_000, scopes: %w[user:inference] },
  )

  let(:server) { FakeLlamaServer.new }
  let(:decoy) { FakeLlamaServer.new }
  let(:settings) do
    Mimic::LlmConfig::Settings.allocate.tap do |cfg|
      llama = Mimic::LlmConfig::LlamaSettings.new({ "llama" => { "port" => server.port } })
      model = instance_double(Mimic::LlmConfig::ModelSettings, name: "my-model", context_length: 200_000)
      allow(cfg).to receive_messages(llama: llama, model: model)
    end
  end

  around do |example|
    Dir.mktmpdir do |home|
      @home = Pathname.new(home)
      names = %w[HOME ANTHROPIC_BASE_URL ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN]
      saved = ENV.to_h.slice(*names)
      names.each { |name| ENV.delete(name) }
      ENV["HOME"] = home
      (@home / ".claude").mkpath
      @oauth_login = ReadDetector.new(@home / ".claude/.credentials.json", OAUTH_LOGIN)
      ENV["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:#{decoy.port}"
      example.run
    ensure
      names.each { |name| ENV.delete(name) }
      ENV.update(saved)
      @oauth_login&.stop
      server.stop
      decoy.stop
    end
  end

  before do
    stub_const("Mimic::Paths::CLAUDE_CONFIG_DIR", @home / "mimic-claude")
    stub_const("Mimic::Paths::MCP_SERVERS_PATH", @home / "no-mcp-servers.json")
  end

  it "sends every `claude -p` request to the llama.port in the config" do
    skip "claude is not installed" unless described_class.find_binary

    output = nil
    allow(Mimic::Agent).to receive(:spawn_and_wait) do |command, env|
      executable = Mimic::Util::Probes.which(command.first)
      output, status = Timeout.timeout(120) do
        Open3.capture2e(env, executable, *command[1..], stdin_data: "")
      end
      status.exitstatus
    end
    elsewhere = JSON.generate({ env: { ANTHROPIC_BASE_URL: "http://127.0.0.1:#{decoy.port}" } })

    agent = described_class.new(settings)
    expect { agent.launch(["-p", "ping", "--settings", elsewhere]) }.not_to raise_error

    requests = Array.new(server.requests.size) { server.requests.pop }
    messages = requests.select { |r| r[:line].match?(FakeLlamaServer::MESSAGES) }
    expect(output).to include(FakeLlamaServer::REPLY)
    expect(decoy.requests).to be_empty
    expect(@oauth_login).not_to be_opened
    expect(messages).not_to be_empty
    expect(messages.map { |r| r[:headers]["host"] }.uniq).to eq(["127.0.0.1:#{server.port}"])
    expect(messages.map { |r| r[:headers]["authorization"] }.uniq).to eq(["Bearer #{Mimic::Agent::AUTH_TOKEN}"])
    expect(messages.map { |r| JSON.parse(r[:body])["model"] }.uniq).to eq(["my-model"])
  end
end
