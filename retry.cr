class Retry
  getter config : Config

  def initialize(@config)
  end

  def configure(&c : Config -> Config)
    self.config = yield @config
  end

  def config=(@config)
    # hook setter
  end

  def run(&action)
    do_or_retry(0, &action)
  end

  private def do_or_retry(retry_count : Int32, &action)
    begin
      yield
    rescue err
      raise err unless @config.retry_errors.any? { |t| t === err } # TODO there is a bug for t === err
      raise Retry::Error.new(retry_count, err) unless (retry_count += 1) <= @config.retry_times
      timeout = @config.retry_timeout_fn.call(err, retry_count)
      sleep timeout
      do_retry(retry_count, &action)
    end
  end

  def self.on(error : T.class, retry_times : Int32, retry_timeout : Time::Span | (T, Int32 -> Time::Span), &) forall T
    Retry::Util.assert_gt retry_times: retry_times, __: 0
    retry_count = 0
    loop do
      begin
        return yield
      rescue err : T
        raise Retry::Error.new(retry_count, err) unless (retry_count += 1) <= retry_times
        if retry_timeout.is_a? Time::Span
          timeout = retry_timeout
        else
          timeout = retry_timeout.call err, retry_count
        end
        sleep timeout
      end
    end
  end
end

# ------ Error ----------------------------------------------

class Retry::Error < Exception
  def initialize(retry_count : Int32, cause : Exception)
    super("Retry error: reached retry_times:(#{retry_count})", cause)
  end
end

# ------ Config --------------------------------------------

record Retry::Config,
  retry_times : Int32,
  retry_errors : Array(Exception.class),
  retry_timeout_fn : Proc(Exception, Int32, Time::Span) do
  def initialize(
    @retry_times : Int32,
    @retry_errors : Array(Exception.class) = [Exception],
    &@retry_timeout_fn : Exception, Int32 -> Time::Span
  )
    Retry::Util.assert_gt(retry_times: retry_times, __: 0)
  end
end

# -------- Util --------------------------------------------

struct Retry::Util
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

# ------ Test -----------------------------------------------

require "spec"

describe Retry::Config do
  it "new" do
    config = Retry::Config.new(retry_times: 3) { |err, count| 1.seconds }
    config.retry_times.should eq 3
    config.retry_errors.should eq [Exception]
  end
end

describe Retry do
  it "on" do
    run_times = 0
    retry_times = 3
    retry_timeout = 1.seconds
    st = Time.monotonic
    expect_raises Retry::Error do
      Retry.on(Exception, retry_times, retry_timeout) {
        run_times += 1
        raise Exception.new("an error 😓")
      }
    end
    elapsed = (Time.monotonic - st).total_seconds.to_i32
    elapsed.should eq (retry_timeout * retry_times).total_seconds.to_i32
    run_times.should eq(retry_times + 1)
  end
  it "on #2" do
    result = Retry.on(Exception, 3, 1.seconds) { "ok" }
    result.should eq "ok"
  end
end
