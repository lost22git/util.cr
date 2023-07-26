class Timeout
  def self.run(timeout : Time::Span, &action : -> T) forall T
    chan = Channel(T | Exception).new(1)
    spawn {
      sleep timeout
      chan.send Error.new(timeout)
    }
    spawn {
      begin
        chan.send action.call
      rescue err
        chan.send err
      end
    }
    result = chan.receive
    raise result if result.is_a?(Exception)
    result
  end
end

class Timeout::Error < Exception
  def initialize(timeout : Time::Span)
    super("Timeout error: timeout:(#{timeout})")
  end
end

# ------ Test -----------------------------------------------

require "spec"

describe Timeout do
  it "run with timeout" do
    st = Time.monotonic
    timeout = 1.seconds
    expect_raises Timeout::Error do
      result = Timeout.run(timeout) {
        sleep 3.seconds
        "ok"
      }
    end
    elapsed = (Time.monotonic - st).total_seconds.to_i32
    elapsed.should eq timeout.total_seconds.to_i32
  end

  it "run without timeout" do
    result = Timeout.run(1.second) {
      "ok"
    }
    result.should eq "ok"
  end

  it "run without timeout but err" do
    expect_raises IO::Error do
      Timeout.run(1.seconds) { raise IO::Error.new("an io error") }
    end
  end
end
