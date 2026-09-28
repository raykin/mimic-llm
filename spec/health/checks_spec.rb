require_relative "../../lib/mimic"
require "socket"
require "tmpdir"

RSpec.describe Mimic::Health::Checks do
  before { allow(Open3).to receive(:capture2).and_raise(Errno::ENOENT) }

  def settings(port: 8080)
    Mimic::LlmConfig::Settings.new(
      "model" => { "path" => "/m.gguf" },
      "llama" => { "host" => "127.0.0.1", "port" => port },
    )
  end

  def row(name, port: 8080) = described_class.new(settings(port: port)).to_a.to_h.fetch(name)

  it "lists every component in report order" do
    allow(Mimic::Util::Probes).to receive(:get).and_raise(Errno::ECONNREFUSED)

    names = described_class.new(settings).to_a.map(&:first)

    expect(names).to eq(["llama.cpp", "Hermes binary", "Hermes DB", "claude-code", "Claude config dir"])
  end

  describe "the llama.cpp row" do
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
        @path = client.gets.split[1]
        client.print("HTTP/1.1 #{@status} Nope\r\nContent-Length: 0\r\n\r\n")
        client.close
      end
    end

    def llama_row = row("llama.cpp", port: @server.addr[1])

    it "reports ok with the HTTP status line for a 2xx from the Settings' models_url" do
      @status = 200
      result = llama_row
      expect(result.ok?).to be true
      expect(result.message).to eq("HTTP 200")
      expect(@path).to eq("/v1/models")
    end

    it "reports not ok for a non-2xx response" do
      @status = 500
      expect(llama_row.ok?).to be false
    end

    it "returns the exception message instead of raising when the connection fails" do
      result = row("llama.cpp", port: 1)
      expect(result.ok?).to be false
      expect(result.message).not_to be_empty
    end
  end

  describe "the Hermes DB row" do
    around do |example|
      Dir.mktmpdir do |dir|
        @db = Pathname.new(dir) / "state.db"
        example.run
      end
    end

    before { allow(Mimic::Util::Probes).to receive(:get).and_raise(Errno::ECONNREFUSED) }

    def seed(sql)
      IO.popen(["sqlite3", @db.to_s], "w") { |io| io.write(sql) }
    end

    def db_result
      stub_const("Mimic::Agent::Hermes::STATE_DB", @db)
      row("Hermes DB")
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
end
