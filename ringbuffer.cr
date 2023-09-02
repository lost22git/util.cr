# a ring buffer with write/read position
#
# we store write/read position by mod 2 times of buffer size
#
# and write/read pos mod 1 time of buffer size to index value

class RingBuffer(T)
  include Enumerable(T)
  include Iterable(T)

  @rpos : Int32 = 0
  @wpos : Int32 = 0

  getter size : Int32

  @ptr : Pointer(T)

  def initialize(@ptr : Pointer(T), size : Int)
    @size = size.to_i32
  end

  def self.new(size : Int)
    {% unless Number::Primitive.union_types.includes?(T) %}
      {% raise "Can only use primitive integers and floats with Slice.new(size), not #{T}" %}
    {% end %}

    ptr = Pointer(T).malloc(size)
    new(ptr, size)
  end

  def mask(pos : Int) : Int
    pos % @size
  end

  def mask2(pos : Int) : Int
    pos % (2 * @size)
  end

  def len : Int
    real_wpos = @wpos < @rpos ? (2*@size) + @wpos : @wpos
    real_wpos - @rpos
  end

  def full? : Bool
    mask2(@wpos + @size) == @rpos
  end

  def empty? : Bool
    @rpos == @wpos
  end

  def write(value : T)
    raise FullError.new if full?
    unsafe_write(value)
  end

  def write?(value : T) : Bool
    begin
      write(T)
      return true
    rescue e
      return false
    end
  end

  def unsafe_write(value : T)
    @ptr[mask(@wpos)] = value
    @wpos = mask2(@wpos + 1)
  end

  def write_slice(slice : Slice(T))
    raise FullError.new unless (len() + slice.size <= @size)
    unsafe_write_slice(slice)
  end

  def unsafe_write_slice(slice : Slice(T))
    slice.each { |v| unsafe_write(v) }
  end

  def read : T | Nil
    return nil if empty?
    unsafe_read
  end

  def unsafe_read : T
    value = @ptr[mask(@rpos)]
    @rpos = mask2(@rpos + 1)
    return value
  end

  def read(& : T -> Bool)
    count = len()
    loop do
      return unless count > 0
      count -= 1
      value = unsafe_read
      return unless (yield value)
    end
  end

  def get(pos : Int) : T
    return @ptr[mask(pos)]
  end

  def next_pos(pos : Int) : Int
    return mask2(pos + 1)
  end

  # impl Enumerable for RingBuffer
  # just get, do not move the read pos
  def each(& : T ->)
    pos = value = @rpos
    len().times.each do |_|
      value = get(pos)
      pos = next_pos(pos)
      yield value
    end
  end

  # impl Iterable for RingBuffer
  # just get, do not move the read pos
  def each
    return Iter(T).new(self)
  end
end

class RingBuffer::Iter(T)
  include Iterator(T)

  @pos : Int32
  @rest : Int32

  def initialize(@rb : RingBuffer(T))
    @pos = @rb.@rpos
    @rest = @rb.len.to_i32
  end

  def next
    return nil unless @rest > 0
    @rest -= 1
    value = @rb.get(@pos)
    @pos = @rb.next_pos(@pos)
    return value
  end
end

# ------ Error ----------------------------------------------

class RingBuffer::FullError < Exception
  def initialize(message = "ringbuffer is full")
    super(message)
  end
end

# ------ Test -----------------------------------------------

require "spec"

describe "RingBuffer" do
  it "new" do
    rb = RingBuffer(Int32).new(10)
    rb.size.should eq 10
  end

  it "mask" do
    rb = RingBuffer(Int32).new(10)
    rb.mask(0).should eq 0
    rb.mask(10).should eq 0
    rb.mask(5).should eq 5
    rb.mask(15).should eq 5
  end

  it "write" do
    rb = RingBuffer(Int32).new(10)
    10.times.each { |i| rb.write(i) }
    expect_raises RingBuffer::FullError do
      rb.write(1)
    end
  end

  it "write_slice" do
    rb = RingBuffer(Int32).new(10)
    slice = Slice(Int32).new(10)
    rb.write_slice(slice)
    expect_raises RingBuffer::FullError do
      rb.write(1)
    end
  end

  it "read" do
    rb = RingBuffer(Int32).new(10)
    2.times.each { |i| rb.write(i) }
    rb.read.should eq 0
    rb.read.should eq 1
    rb.read.nil?.should be_true
  end

  it "read &" do
    rb = RingBuffer(Int32).new(10)
    10.times.each { |i| rb.write(i) }

    count = 0
    rb.read do |i|
      i.should eq count
      count += 1
      next count < 5
    end
    count.should eq 5

    rb.read do |i|
      i.should eq count
      count += 1
      next count < 15
    end
    count.should eq 10
  end

  it "each for Enumerable" do
    rb = RingBuffer(Int32).new(10)
    10.times.each { |i| rb.write(i) }
    5.times.each { rb.read }

    rb.map { |i| i - 5 }.to_a.should eq (0..4).to_a
    rb.read.should eq 5
  end

  it "each for Iterable" do
    rb = RingBuffer(Int32).new(10)
    10.times.each { |i| rb.write(i) }
    5.times.each { rb.read }
    5.times.each { |i| rb.write(10 + i) }

    iter = rb.each
    (5..14).each { |i| iter.next.should eq i }
    iter.next.should be_nil
    rb.read.should eq 5
  end
end
