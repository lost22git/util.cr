require "bit_array"

class CircuitBreaker
  getter config : Config
  getter status : Status = Status::Close
  getter stat : Stat
  @status_lock : Mutex = Mutex.new(Mutex::Protection::Reentrant)

  # half_open 状态下的已执行个数
  @num_on_half_open : Atomic(Int32) = Atomic(Int32).new(0)

  # open -> half_open 任务的 timer id
  @timer_id_to_half_open : Atomic(Int32) = Atomic(Int32).new(0)

  def initialize(@config)
    @stat = Stat.new(config.win_num)
  end

  def configure(&c : Config -> Config)
    self.config = yield @config
  end

  def config=(@config)
    # hook setter
  end

  def run(&)
    acquire
    begin
      yield
      record_ok
    rescue e
      record_err
      raise e
    ensure
      release
    end
  end

  # 请求执行权, 一般用于 before filter
  def acquire?
    begin
      acquire
      true
    rescue
      false
    end
  end

  # 请求执行权，一般用于 before filter
  def acquire
    case @status
    in .close?
      return
    in .open?
      raise CircuitBreaker::OpenError.new
    in .half_open?
      while true
        old = @num_on_half_open.get
        max = @config.max_num_on_half_open
        raise CircuitBreaker::HalfOpenMaxNumReachError.new(max) if old >= max
        return if @num_on_half_open.compare_and_set(old, old + 1)[1]
      end
    end
  end

  # 释放执行权，一般用于 after filter
  def release
    if @status.half_open?
      while true
        old = @num_on_half_open.get
        new = old > 0 ? old - 1 : 0
        return if @num_on_half_open.compare_and_set(old, new)[1]
      end
    end
  end

  # 记录执行成功
  def record_ok
    @stat.record_ok
    check_status
  end

  # 记录执行失败
  def record_err
    @stat.record_err
    check_status
  end

  # 检查状态和 stat, 如果符合条件则状态转移
  #
  # | current status |              condition                 | status transition  |
  # |:--------------:|:--------------------------------------:|:------------------:|
  # | close          | stat.err_num >= config.err_num_to_open | close -> open      |
  # | open           | config.time_span_to_half_open timeout  | open -> half_open  |
  # | half_open      | stat.ok_num >= config.ok_num_to_close  | half_open -> close |
  # | half_open      | stat.err_num >= config.err_num_to_open | half_open -> open  |
  #
  private def check_status
    @status_lock.synchronize do
      stat_get = @stat.get
      ok_num = stat_get[:ok]
      err_num = stat.get[:err]
      err_num_to_open = @config.err_num_to_open
      ok_num_to_close = @config.ok_num_to_close

      case @status
      in .close?
        update_status(Status::Open) if err_num >= err_num_to_open
      in .open?
        # noth
      in .half_open?
        if ok_num >= ok_num_to_close
          update_status(Status::Close)
        elsif err_num >= err_num_to_open
          update_status(Status::Open)
        else
          # noth
        end
      end
    end
  end

  # 强行熔断
  def force_open
    update_status(Status::Open)
  end

  # 强行恢复
  def force_close
    update_status(Status::Close)
  end

  # 状态转移, clear=true 时重置 stat
  private def update_status(new_status : Status, clear : Bool = true)
    @status_lock.synchronize do
      return if @status == new_status

      # @status 更新为新状态
      @status = new_status
      @stat = Stat.new(@config.win_num) if clear

      # 更新状态后的一些额外工作
      if new_status.half_open?
        @num_on_half_open.set(0)
      elsif new_status.open?
        # TODO: abstract it
        # 定时任务：open -> half_open
        # timer_id 自增, 避免重复执行(取消上次)
        timer_id = @timer_id_to_half_open.add(1) + 1
        spawn do
          sleep @config.time_span_to_half_open
          update_status(Status::HalfOpen) if @status.open? && @timer_id_to_half_open.get == timer_id
        end
      else
        # noth
      end
    end
  end
end

# -------- Error -------------------------------------------

abstract class CircuitBreaker::Error < Exception
  def initialize(message = "CircuitBreaker error")
    super(message)
  end
end

class CircuitBreaker::OpenError < CircuitBreaker::Error
  def initialize
    super("CircuitBreaker error: open")
  end
end

class CircuitBreaker::HalfOpenMaxNumReachError < CircuitBreaker::Error
  def initialize(max_num : Int32)
    super("CircuitBreaker error: reached max_num_on_half_open:(#{max_num})")
  end
end

# -------- Status ------------------------------------------

enum CircuitBreaker::Status
  Close
  Open
  HalfOpen
end

# -------- Stat --------------------------------------------

# TODO 基于时间窗口的实现

struct CircuitBreaker::Stat
  @win_num : Int32
  @win : BitArray
  @pos : Atomic(Int32) = Atomic(Int32).new(0)

  def initialize(@win_num : Int32)
    CircuitBreaker::Util.assert_gt(win_num: win_num, __: 0)
    @win = BitArray.new(win_num)
  end

  # stat 快照
  def get : NamedTuple(ok: Int32, err: Int32)
    pos = @pos.get
    if pos < @win_num
      ok_num = @win[0...pos].count(true)
      err_num = pos - ok_num
    else
      ok_num = @win.count(true)
      err_num = @win_num - ok_num
    end
    {ok: ok_num, err: err_num}
  end

  # 记录一个成功
  def record_ok
    pos = @pos.add(1) % @win_num
    @win[pos] = true
  end

  # 记录一个失败
  def record_err
    pos = @pos.add(1) % @win_num
    @win[pos] = false
  end
end

# -------- Config ------------------------------------------

record CircuitBreaker::Config,
  win_num : Int32,
  err_num_to_open : Int32,
  ok_num_to_close : Int32,
  max_num_on_half_open : Int32,
  time_span_to_half_open : Time::Span do
  def initialize(
    @win_num : Int32,
    @err_num_to_open : Int32,
    @ok_num_to_close : Int32,
    @max_num_on_half_open : Int32,
    @time_span_to_half_open : Time::Span
  )
    {% for arg in %w[win_num err_num_to_open ok_num_to_close max_num_on_half_open] %}
      CircuitBreaker::Util.assert_gt({{arg.id}}: {{arg.id}}, __:0)
    {% end %}

    CircuitBreaker::Util.assert_ge(max_num_on_half_open: max_num_on_half_open, win_num: win_num)

    CircuitBreaker::Util.assert_ge(win_num: win_num, err_num_to_open: err_num_to_open)
    CircuitBreaker::Util.assert_ge(win_num: win_num, ok_num_to_close: ok_num_to_close)
  end
end

# -------- Util --------------------------------------------

struct CircuitBreaker::Util
  def self.assert(msg : String, &)
    raise ArgumentError.new(msg) unless yield
  end

  {% for name, op in {gt: ">", ge: ">=", lt: "<", le: "<=", eq: "=="} %}
    {% method_name = "assert_#{name}" %}
    def self.{{method_name.id}}(**args)
      keys = args.keys
      lk = keys[0]
      rk = keys[1]
      lv = args[lk]
      rv = args[rk]
      if rk == :__
        raise ArgumentError.new "assert: #{lk}:(#{lv}) "+{{op}}+" #{rv}" unless lv {{op.id}} rv
      else
        raise ArgumentError.new "assert: #{lk}:(#{lv}) "+{{op}}+" #{rk}:(#{rv})" unless lv {{op.id}} rv
      end
    end
  {% end %}
end

# ------ Test ---------------------------------------------

require "spec"

describe CircuitBreaker::Config do
  it "new" do
    config = CircuitBreaker::Config.new(
      win_num: 100,
      err_num_to_open: 66,
      ok_num_to_close: 66,
      time_span_to_half_open: Time::Span.new(seconds: 10),
      max_num_on_half_open: 100
    )
    config.win_num.should eq 100
    config.err_num_to_open.should eq 66
    config.ok_num_to_close.should eq 66
    config.time_span_to_half_open.should eq Time::Span.new(seconds: 10)
    config.max_num_on_half_open.should eq 100
  end
  it "assert err_num_to_open > 0" do
    expect_raises ArgumentError do
      CircuitBreaker::Config.new(
        win_num: 100,
        err_num_to_open: 0,
        ok_num_to_close: 66,
        time_span_to_half_open: Time::Span.new(seconds: 10),
        max_num_on_half_open: 100
      )
    end
  end
  it "assert ok_num_to_close > 0" do
    expect_raises ArgumentError do
      CircuitBreaker::Config.new(
        win_num: 100,
        err_num_to_open: 66,
        ok_num_to_close: 0,
        time_span_to_half_open: Time::Span.new(seconds: 10),
        max_num_on_half_open: 100
      )
    end
  end
  it "assert win_num >= err_num_to_open" do
    expect_raises ArgumentError do
      CircuitBreaker::Config.new(
        win_num: 10,
        err_num_to_open: 66,
        ok_num_to_close: 66,
        time_span_to_half_open: Time::Span.new(seconds: 10),
        max_num_on_half_open: 100
      )
    end
  end
  it "assert win_num >= ok_num_to_close" do
    expect_raises ArgumentError do
      CircuitBreaker::Config.new(
        win_num: 10,
        err_num_to_open: 6,
        ok_num_to_close: 66,
        time_span_to_half_open: Time::Span.new(seconds: 10),
        max_num_on_half_open: 100
      )
    end
  end
  it "assert win_num <= max_num_on_half_open" do
    expect_raises ArgumentError do
      CircuitBreaker::Config.new(
        win_num: 10,
        err_num_to_open: 6,
        ok_num_to_close: 66,
        time_span_to_half_open: Time::Span.new(seconds: 10),
        max_num_on_half_open: 9
      )
    end
  end
end

describe CircuitBreaker::Stat do
  it "record and get" do
    stat = CircuitBreaker::Stat.new(100)
    5.times { stat.record_ok }
    5.times { stat.record_err }
    stat.get[:ok].should eq 5
    stat.get[:err].should eq 5

    5.times { stat.record_ok }
    15.times { stat.record_err }
    stat.get[:ok].should eq 10
    stat.get[:err].should eq 20

    60.times { stat.record_ok }
    stat.get[:ok].should eq 70
    stat.get[:err].should eq 20

    # full of win
    10.times { stat.record_ok }
    stat.get[:ok].should eq 80
    stat.get[:err].should eq 20

    # overflow and rewrite old bits
    10.times { stat.record_err }
    stat.get[:ok].should eq 75
    stat.get[:err].should eq 25
  end
end

config = CircuitBreaker::Config.new(
  win_num: 10,
  err_num_to_open: 6,
  ok_num_to_close: 6,
  time_span_to_half_open: Time::Span.new(seconds: 10),
  max_num_on_half_open: 20
)

describe CircuitBreaker do
  it "initialize" do
    cb = CircuitBreaker.new(config)
    cb.should_not be_nil
    cb.config.should eq config
    cb.status.should eq CircuitBreaker::Status::Close
    cb.stat.get[:ok].should eq 0
    cb.stat.get[:err].should eq 0
  end
  it "configure" do
    cb = CircuitBreaker.new(config)
    cb.configure do |c|
      c.copy_with(win_num: 11)
    end
    cb.config.win_num.should eq 11
  end
  it "force_open / force_close" do
    cb = CircuitBreaker.new(config)
    cb.force_open
    cb.status.should eq CircuitBreaker::Status::Open
    cb.stat.get[:ok].should eq 0
    cb.stat.get[:err].should eq 0
    cb.force_close
    cb.status.should eq CircuitBreaker::Status::Close
    cb.stat.get[:ok].should eq 0
    cb.stat.get[:err].should eq 0
  end
  it "acquire? / acquire" do
    cb = CircuitBreaker.new(config)
    cb.acquire?.should be_true
    cb.force_open
    cb.acquire?.should be_false
    expect_raises CircuitBreaker::Error do
      cb.acquire
    end
  end
  it "run" do
  end
end
