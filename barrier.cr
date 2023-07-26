class Barrier
  @count : Int32
  @action : Proc(Barrier, Nil)
  @wait_count : Atomic(Int32)
  @fibers : Array(Fiber)
  @lock : Mutex = Mutex.new

  def initialize(count : Int32)
    initialize(count) { }
  end

  def initialize(count : Int32, &action : (Barrier ->))
    raise ArgumentError.new "count must be > 0" unless count > 0
    @count = count
    @wait_count = Atomic(Int32).new count
    @fibers = Array(Fiber).new count - 1 # last one no need add
    @action = action
  end

  def wait
    c = @wait_count.sub(1)
    if c == 1 # last one
      @action.call self
      @lock.synchronize {
        @fibers.each &.enqueue # notify all fibers to continue
        @fibers.clear
      }
    elsif c < 1
      return
    else
      @lock.synchronize {
        @fibers << Fiber.current
      }
      Fiber.yield # yield current fiber
    end
  end

  def reset
    raise Exception.new "exists waiters" unless @wait_count.get == 0
    @wait_count.set @count
  end
end

# Test
count = 5
barrier = Barrier.new count, &.reset
chan = Channel(Nil).new

2.times do |i|
  #  p! barrier
  st = Time.monotonic
  count.times { |i|
    spawn {
      puts "fiber #{i} wait\n"
      barrier.wait
      puts "fiber #{i} sleep\n"
      sleep 1
      chan.send(nil)
    }
  }
  count.times { chan.receive }
  elapsed = (Time.monotonic - st).total_milliseconds
  puts "step#{i + 1} finished, elapsed=#{elapsed}ms\n"
end

puts "all finished\n"
