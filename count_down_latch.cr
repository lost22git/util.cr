class CountDownLatch
  def initialize(count : Int32)
    raise ArgumentError.new "count must be > 0" unless count > 0
    @chan = Channel(Nil).new count
  end

  def wait
    @chan.receive
  end

  def count_down
    @chan.send nil
  end
end

# ------ Test -----------------------------------------------

require "spec"

describe CountDownLatch do
  it "test count_down and wait" do
    count = 5
    latch = CountDownLatch.new count
    count.times { |i|
      spawn {
        sleep 1
        latch.count_down
        puts "Fiber #{i} done"
      }
    }
    latch.wait
  end
end
