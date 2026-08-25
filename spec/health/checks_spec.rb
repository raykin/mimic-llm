require_relative "../../lib/mimic"
require "socket"
require "tmpdir"

RSpec.describe Mimic::Health::Checks do
  describe ".service" do
    around do |example|
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { serve }
      example.run
    ensure
      @thread&.kill
      @server.close
    end

    def serve
      loop do
        client = @server.accept
        client.gets
        client.print("HTTP/1.1 #{@status} Nope\r\nContent-Length: 0\r\n\r\n")
        client.close
      end
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}/"

    it "reports ok with the HTTP status line for a 2xx response" do
      @status = 200
      result = described_class.service(url, timeout: 2)
      expect(result.ok?).to be true
      expect(result.message).to eq("HTTP 200")
    end

    it "reports not ok for a non-2xx response" do
      @status = 500
      result = described_class.service(url, timeout: 2)
      expect(result.ok?).to be false
    end

    it "returns the exception message instead of raising when the connection fails" do
      result = described_class.service("http://127.0.0.1:1/", timeout: 1)
      expect(result.ok?).to be false
      expect(result.message).not_to be_empty
    end
  end

  describe "#db" do
    around do |example|
      Dir.mktmpdir do |dir|
        @db = Pathname.new(dir) / "state.db"
        example.run
      end
    end

    def seed(sql)
      IO.popen(["sqlite3", @db.to_s], "w") { |io| io.write(sql) }
    end

    def db_result
      stub_const("Mimic::Agent::Hermes::STATE_DB", @db)
      described_class.new(Mimic::LlmConfig::Settings.new({})).send(:db)
    end

    it "counts active messages and total tokens" do
      seed(<<~SQL)
        CREATE TABLE messages (active INTEGER);
        INSERT INTO messages VALUES (1), (1), (0);
        CREATE TABLE sessions (input_tokens INTEGER, output_tokens INTEGER);
        INSERT INTO sessions VALUES (100, 200), (10, 20);
      SQL

      result = db_result

      expect(result.ok?).to be true
      expect(result.message).to eq("2 messages, 330 tokens total")
    end

    it "reports not ok when the database file is absent" do
      expect(db_result.ok?).to be false
    end

    # Hermes owns this schema and can change it without telling mimic, so a
    # rename has to read as one failed row rather than taking down `verify`.
    it "reports not ok when the schema is not what Hermes used to write" do
      seed("CREATE TABLE unrelated (x INTEGER);")

      result = db_result

      expect(result.ok?).to be false
      expect(result.message).not_to be_empty
    end
  end

  describe "#to_a" do
    it "probes llama.cpp at the Settings' own models_url" do
      settings = Mimic::LlmConfig::Settings.new(
        "model" => { "path" => "/m.gguf" },
        "llama" => { "host" => "127.0.0.1", "port" => 8080 },
      )
      allow(described_class).to receive(:service).and_return(Mimic::Result.ok("HTTP 200"))

      names = described_class.new(settings).to_a.map(&:first)

      expect(described_class).to have_received(:service).with(Mimic::Engine::Llama.new(settings).models_url)
      expect(names).to eq(["llama.cpp", "Hermes binary", "Hermes DB", "claude-code", "Claude config dir"])
    end
  end
end
