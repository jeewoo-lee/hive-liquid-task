# frozen_string_literal: true

target_root = File.expand_path(ARGV.fetch(0))
$LOAD_PATH.unshift(File.join(target_root, "lib"))
load File.join(target_root, "performance/theme_runner.rb")

RubyVM::YJIT.enable if defined?(RubyVM::YJIT)

module EvalBenchTarget
  module_function

  def salted_source(source, salt)
    return nil unless source

    "#{source}\n{% comment %}eval-cold-parse:#{salt}{% endcomment %}"
  end

  # Walk all modules/classes under the Liquid namespace.
  def each_liquid_module
    seen = {}
    queue = [Liquid]
    while (mod = queue.shift)
      next if seen[mod.object_id]
      seen[mod.object_id] = true
      yield mod
      mod.constants(false).each do |c|
        begin
          val = mod.const_get(c, false)
          queue << val if val.is_a?(Module)
        rescue
          # skip autoload or uninitialized constants
        end
      end
    end
  end

  # Snapshot all mutable Hash class/module instance variables and class
  # variables under the Liquid namespace. Returns a hash of snapshots.
  def snapshot_liquid_state
    snapshots = {}
    each_liquid_module do |mod|
      mod.instance_variables.each do |ivar|
        val = mod.instance_variable_get(ivar)
        snapshots[[mod, :ivar, ivar]] = val.dup if val.is_a?(Hash) && !val.frozen?
      end
      mod.class_variables.each do |cv|
        val = mod.class_variable_get(cv)
        snapshots[[mod, :cvar, cv]] = val.dup if val.is_a?(Hash) && !val.frozen?
      end if mod.respond_to?(:class_variables)
    end
    snapshots
  end

  # Restore all mutable Hash state to a previous snapshot.
  # Hashes added during warmup (not in snapshot) are cleared.
  # Hashes that existed but grew during warmup are restored.
  # This prevents cross-template/cross-iteration cache exploitation
  # while preserving legitimate state (operator tables, tag registrations).
  def restore_liquid_state(snapshots)
    each_liquid_module do |mod|
      mod.instance_variables.each do |ivar|
        val = mod.instance_variable_get(ivar)
        next unless val.is_a?(Hash) && !val.frozen?
        key = [mod, :ivar, ivar]
        if snapshots.key?(key)
          val.replace(snapshots[key])
        else
          val.clear
        end
      end
      next unless mod.respond_to?(:class_variables)
      mod.class_variables.each do |cv|
        val = mod.class_variable_get(cv)
        next unless val.is_a?(Hash) && !val.frozen?
        key = [mod, :cvar, cv]
        if snapshots.key?(key)
          val.replace(snapshots[key])
        else
          val.clear
        end
      end
    end
  end
end

runner = ThemeRunner.new
tests = runner.instance_variable_get(:@tests)

raise "ThemeRunner test corpus did not load" unless tests.is_a?(Array) && !tests.empty?

# Snapshot all mutable class-level Hash state BEFORE warmup.
# This captures legitimate state (operator tables, tag registrations, etc.)
# and excludes any caches that warmup will populate.
pre_warmup_state = EvalBenchTarget.snapshot_liquid_state

# Warm up render paths with the real compiled templates.
20.times { runner.render }

# Warm up parser paths using salted variants so whole-document parse caches
# cannot make the parse benchmark artificially free.
20.times do |iter|
  tests.each_with_index do |test_hash, idx|
    salt = "warmup-#{iter}-#{idx}"
    Liquid::Template.new.parse(EvalBenchTarget.salted_source(test_hash[:liquid], salt))
    layout = test_hash[:layout]
    Liquid::Template.new.parse(EvalBenchTarget.salted_source(layout, salt)) if layout
  end
end

GC.start
GC.compact if GC.respond_to?(:compact)

# Restore pre-warmup state: clears any caches populated during warmup
EvalBenchTarget.restore_liquid_state(pre_warmup_state)

parse_times = []
10.times do |iter|
  GC.disable
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  tests.each_with_index do |test_hash, idx|
    salt = "parse-#{iter}-#{idx}"
    Liquid::Template.new.parse(EvalBenchTarget.salted_source(test_hash[:liquid], salt))
    layout = test_hash[:layout]
    Liquid::Template.new.parse(EvalBenchTarget.salted_source(layout, salt)) if layout
  end
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  GC.enable
  GC.start
  parse_times << (t1 - t0) * 1_000_000
end

# Restore state before render timing
EvalBenchTarget.restore_liquid_state(pre_warmup_state)

render_times = []
10.times do
  GC.disable
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  runner.render
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  GC.enable
  GC.start
  render_times << (t1 - t0) * 1_000_000
end

# Restore state before allocation measurement
EvalBenchTarget.restore_liquid_state(pre_warmup_state)

require "objspace"
GC.start
GC.disable
before = ObjectSpace.count_objects.values_at(:TOTAL).first - ObjectSpace.count_objects.values_at(:FREE).first
runner.send(:each_test) do |liquid, layout, assigns, page_template, template_name|
  salt = "alloc-#{template_name}"
  compiled = runner.send(
    :compile_test,
    EvalBenchTarget.salted_source(liquid, salt),
    EvalBenchTarget.salted_source(layout, salt),
    assigns,
    page_template,
    template_name,
  )
  runner.send(:render_layout, compiled[:tmpl], compiled[:layout], compiled[:assigns])
end
after = ObjectSpace.count_objects.values_at(:TOTAL).first - ObjectSpace.count_objects.values_at(:FREE).first
GC.enable

parse_us = parse_times.min.round(0)
render_us = render_times.min.round(0)
combined_us = parse_us + render_us
allocations = after - before

puts "RESULTS"
puts "parse_us=#{parse_us}"
puts "render_us=#{render_us}"
puts "combined_us=#{combined_us}"
puts "allocations=#{allocations}"
