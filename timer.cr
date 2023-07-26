struct Timer::TimeoutId
  @@NEXT_ID = Atomic(UInt32).new(0)

  getter id : UInt32

  protected def initialize
    @id = @@NEXT_ID.add(1)
  end
end

module Timer
  # TODO
  # 可能存在无效元素的原因：被成功调度后，用户再次调用 Timer.cancel_timeout
  # 是否需要定时删除无效元素的任务?
  # 如何判断是否无效:
  # 方案1: TimeoutId 添加一个 timeout_unix_ms 字段, 小于 (Time.utc - 1.minutes).to_unix_ms 即无效？
  @@canceled_timeout_ids = Set(TimeoutId).new

  @@lock = Mutex.new

  def self.new_timeout(timeout : Time::Span, &action) : TimeoutId
    t_id = TimeoutId.new
    spawn do
      sleep timeout
      action.call unless remove_canceled_timeout_id?(t_id)
    end
    return t_id
  end

  def self.cancel_timeout(timeout_id : TimeoutId)
    @@lock.synchronize do
      @@canceled_timeout_ids << timeout_id
    end
  end

  def self.every(timeout : Time::Span, &action : (TimeoutId ->))
    t_id = TimeoutId.new
    do_every(t_id, timeout, &action)
  end

  private def self.do_every(timeout_id : TimeoutId, timeout : Time::Span, &action : (TimeoutId ->))
    return if is_canceled?(timeout_id)
    spawn do
      sleep timeout
      unless remove_canceled_timeout_id? timeout_id
        action.call timeout_id
        do_every(timeout_id, timeout, &action)
      end
    end
  end

  private def self.is_canceled?(timeout_id : TimeoutId) : Bool
    @@lock.synchronize do
      @@canceled_timeout_ids.includes? timeout_id
    end
  end

  private def self.remove_canceled_timeout_id?(timeout_id : TimeoutId) : Bool
    @@lock.synchronize do
      return @@canceled_timeout_ids.delete timeout_id
    end
  end
end

# ------ Test -----------------------------------------------

require "spec"

describe Timer do
  it "every and timeout" do
    chan = Channel(Int32).new
    count = 0
    Timer.every(500.milliseconds) do |timeout_id|
      count += 1
      if count == 10
        Timer.cancel_timeout(timeout_id)
      else
        chan.send(count)
      end
    end

    (1..9).each { |i| chan.receive.should eq i }
    Timer.new_timeout(3.seconds) { chan.send(-1) }
    chan.receive.should eq -1
  end
end
