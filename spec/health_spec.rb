require_relative "../lib/mimic"
require "tmpdir"
require "socket"

RSpec.describe Mimic::Health do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  before do
    stub_const("Mimic::Agent::Hermes::AGENT_LOG", @dir / "agent.log")
    stub_const("Mimic::Agent::Hermes::ERRORS_LOG", @dir / "errors.log")
  end

  def stamp(minutes_ago) = (Time.now - (minutes_ago * 60)).strftime("%Y-%m-%d %H:%M:%S")

  describe ".run" do
    def settings
      Mimic::LlmConfig::Settings.new(
        "model" => { "path" => "/m.gguf" },
        "llama" => { "host" => "127.0.0.1", "port" => 8080 },
      )
    end

    def stub_checks(*results)
      allow(Mimic::Health::Checks).to receive(:new)
        .and_return(instance_double(Mimic::Health::Checks, to_a: results))
    end

    it "builds its checks from the Settings it was given and passes when they all do" do
      cfg = settings
      stub_checks(["llama.cpp", Mimic::Result.ok("HTTP 200")])

      expect { expect(described_class.run(cfg)).to be true }.to output.to_stdout
      expect(Mimic::Health::Checks).to have_received(:new).with(cfg)
    end

    it "fails when any single check fails" do
      stub_checks(
        ["llama.cpp", Mimic::Result.ok("HTTP 200")],
        ["Hermes DB", Mimic::Result.error("no such table")],
      )

      expect { expect(described_class.run(settings)).to be false }.to output(/no such table/).to_stdout
    end

    it "fails when the checks pass but the logs hold a recent error" do
      (@dir / "errors.log").write("#{stamp(5)},123 ERROR boom\n")
      stub_checks(["llama.cpp", Mimic::Result.ok("HTTP 200")])

      expect { expect(described_class.run(settings)).to be false }.to output(/ERROR boom/).to_stdout
    end

    describe "counting the Hermes logs" do
      before { stub_checks(["llama.cpp", Mimic::Result.ok("HTTP 200")]) }

      # Regression: `read(encoding: "UTF-8", invalid: :replace)` replaces
      # nothing -- it names an external encoding, which transcodes nothing --
      # so one truncated multibyte character in a hermes log took the whole of
      # `mimic verify` down with an ArgumentError from the regex.
      it "counts and prints an error line that holds an invalid byte" do
        (@dir / "errors.log").binwrite("#{stamp(5)},111 ERROR truncated \xFF\n")

        expect { expect(described_class.run(settings)).to be false }
          .to output(/1 errors, 0 warns.*truncated �/m).to_stdout
      end

      # Deliberate divergence: Python guards the read in count_recent_errors
      # but not in the sample, so an unreadable errors.log crashed `mimic
      # verify` at the point it printed the errors it counted from agent.log.
      it "skips a log it cannot read instead of raising" do
        (@dir / "agent.log").write("#{stamp(5)},123 ERROR readable\n")
        (@dir / "errors.log").write("#{stamp(5)},123 ERROR unreadable\n")
        (@dir / "errors.log").chmod(0o000)

        expect { expect(described_class.run(settings)).to be false }.to output(/1 errors, 0 warns/).to_stdout
      end

      it "prints no sample when there is no errors log" do
        (@dir / "agent.log").write("#{stamp(5)},123 ERROR only here\n")

        expect { described_class.run(settings) }.not_to output(/only here/).to_stdout
      end

      # Python uses re.match, which anchors at the start of the line. A
      # timestamp appearing mid-line is another logger's text, not a hermes
      # record.
      it "ignores a level that is not at the start of the line" do
        (@dir / "agent.log").write("wrapped #{stamp(5)},123 ERROR from another logger\n")

        expect { expect(described_class.run(settings)).to be true }.to output.to_stdout
      end

      it "stops at the first line older than the window" do
        (@dir / "agent.log").write([
          "#{stamp(120)},000 ERROR old\n",
          "#{stamp(10)},000 ERROR recent\n",
          "#{stamp(5)},000 WARNING recent\n",
        ].join)

        expect { described_class.run(settings) }.to output(/1 errors, 1 warns/).to_stdout
      end

      # A retained "\n" prints a blank line after every sampled error, and
      # the 200-character truncation counts it.
      it "prints only the ERROR lines of the sample, one per line" do
        (@dir / "errors.log").write([
          "#{stamp(5)},111 ERROR first\n",
          "#{stamp(4)},222 WARNING skipped\n",
          "#{stamp(3)},333 ERROR second\n",
        ].join)

        expect { described_class.run(settings) }
          .to output(/ERROR first\n  \S+ \S+ ERROR second\n\z/).to_stdout
      end
    end
  end
end
