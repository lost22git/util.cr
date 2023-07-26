require "spec"

class CountDownLatch
  @count : Atomic(Int32)
  @chan : Channel(Nil) = Channel(Nil).new

  def initialize(count : Int32)
    raise Exception.new "count must be > 0" unless count > 0
    @count = Atomic(Int32).new count
  end

  def wait
    @chan.receive
  end

  def count_down
    if @count.sub(1) == 1
      @chan.send nil
    end
  end

  def count : Int32
    @count.get
  end
end

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
    latch.count.should eq 0
  end
end
