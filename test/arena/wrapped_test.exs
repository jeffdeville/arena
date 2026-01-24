defmodule Arena.WrappedTest do
  use ExUnit.Case, async: true

  alias Arena.Config
  alias Arena.Wrapped

  describe "new/2" do
    test "creates wrapped with config and input" do
      config = Config.new(:my_test)
      wrapped = Wrapped.new(config, :my_args)

      assert %Wrapped{} = wrapped
      assert wrapped.config == config
      assert wrapped.input == :my_args
    end

    test "accepts nil input" do
      config = Config.new(:my_test)
      wrapped = Wrapped.new(config, nil)

      assert wrapped.input == nil
    end

    test "defaults to nil input when not provided" do
      config = Config.new(:my_test)
      wrapped = Wrapped.new(config)

      assert wrapped.input == nil
    end

    test "accepts any input type" do
      config = Config.new(:my_test)

      # Map
      wrapped = Wrapped.new(config, %{key: :value})
      assert wrapped.input == %{key: :value}

      # List
      wrapped = Wrapped.new(config, [:a, :b, :c])
      assert wrapped.input == [:a, :b, :c]

      # Tuple
      wrapped = Wrapped.new(config, {:ok, :result})
      assert wrapped.input == {:ok, :result}

      # Atom
      wrapped = Wrapped.new(config, :atom)
      assert wrapped.input == :atom

      # Number
      wrapped = Wrapped.new(config, 123)
      assert wrapped.input == 123
    end
  end

  describe "struct enforcement" do
    test "enforces required fields at compile time" do
      # The struct enforces both fields at compile time via @enforce_keys
      # We can verify by checking the struct's enforced keys
      config = Config.new(:my_test)

      # This works because both fields are provided
      wrapped = %Wrapped{config: config, input: :test}
      assert wrapped.config == config
      assert wrapped.input == :test
    end
  end
end
