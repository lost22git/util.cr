def map(a : A, to b : B.class) : B forall A, B
  {% begin %}
    B.new(
      {% for bvar in B.instance_vars %}
        {% for avar in A.instance_vars %}
          {% if avar.name == bvar.name %}
            {{ avar.name }}: a.{{ avar.name }},
          {% end %}
        {% end %}
      {% end %}
    )
  {% end %}
end

def merge(a : A, with b : B, skip_nil : Bool = false) forall A, B
  {% begin %}
    {% for avar in A.instance_vars %}
      {% for bvar in B.instance_vars %}
        {% if avar.name == bvar.name %}
          if a.responds_to?(:{{ avar.name }}=) && b.responds_to?(:{{ avar.name }})
            unless skip_nil && b.{{ avar.name }}.nil?
              a.{{ avar.name }} = b.{{ avar.name }}
            end
          end
        {% end %}
      {% end %}
    {% end %}
  {% end %}
end

# ------ Test --------------------------

require "spec"
require "json"

enum Color
  Blue
  Red
end

class Foo
  property a_int : Int32
  property a_float : Float32
  property a_bool : Bool
  property a_string : String
  property a_enum : Color
  property a_array : Array(String)
  property a_tuple : Tuple(String, Int32)
  property a_time : Time | Nil

  def initialize(@a_int, @a_float, @a_bool, @a_string, @a_enum, @a_array, @a_tuple, @a_time)
  end

  include JSON::Serializable
end

record Bar,
  a_int : Int32,
  a_float : Float32,
  a_bool : Bool,
  a_string : String,
  a_enum : Color,
  a_array : Array(String),
  a_tuple : Tuple(String, Int32),
  a_time : Time | Nil do
  include JSON::Serializable
end

describe "map/merge" do
  it "map" do
    foo = Foo.new(
      a_int: 1,
      a_float: 1.1_f32,
      a_bool: true,
      a_string: "foo",
      a_enum: Color::Red,
      a_array: ["foo", "bar"],
      a_tuple: {"foo", 1},
      a_time: Time.utc
    )
    bar = map foo, to: Bar
    foo.to_json.should eq bar.to_json
  end

  it "merge" do
    foo = Foo.new(
      a_int: 1,
      a_float: 1.1_f32,
      a_bool: true,
      a_string: "foo",
      a_enum: Color::Red,
      a_array: ["foo", "bar"],
      a_tuple: {"foo", 1},
      a_time: Time.utc
    )
    bar = Bar.new(
      a_int: 2,
      a_float: 2.2_f32,
      a_bool: false,
      a_string: "bar",
      a_enum: Color::Blue,
      a_array: ["bar", "foo"],
      a_tuple: {"bar", 1},
      a_time: nil
    )

    merge foo, with: bar

    foo.a_int.should eq bar.a_int
    foo.a_float.should eq bar.a_float
    foo.a_bool.should eq bar.a_bool
    foo.a_string.should eq bar.a_string
    foo.a_enum.should eq bar.a_enum
    foo.a_array.should eq bar.a_array
    foo.a_tuple.should eq bar.a_tuple
    foo.a_time.should eq bar.a_time
  end

  it "merge skip_nil" do
    foo = Foo.new(
      a_int: 1,
      a_float: 1.1_f32,
      a_bool: true,
      a_string: "foo",
      a_enum: Color::Red,
      a_array: ["foo", "bar"],
      a_tuple: {"foo", 1},
      a_time: Time.utc
    )
    bar = Bar.new(
      a_int: 2,
      a_float: 2.2_f32,
      a_bool: false,
      a_string: "bar",
      a_enum: Color::Blue,
      a_array: ["bar", "foo"],
      a_tuple: {"bar", 1},
      a_time: nil
    )

    merge foo, with: bar, skip_nil: true

    foo.a_int.should eq bar.a_int
    foo.a_float.should eq bar.a_float
    foo.a_bool.should eq bar.a_bool
    foo.a_string.should eq bar.a_string
    foo.a_enum.should eq bar.a_enum
    foo.a_array.should eq bar.a_array
    foo.a_tuple.should eq bar.a_tuple
    foo.a_time.should_not eq bar.a_time # not eq

    foo.a_time.should_not be_nil
    bar.a_time.should be_nil
  end
end
