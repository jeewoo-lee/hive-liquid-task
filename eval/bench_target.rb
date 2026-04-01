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
end

runner = ThemeRunner.new
tests = runner.instance_variable_get(:@tests)

raise "ThemeRunner test corpus did not load" unless tests.is_a?(Array) && !tests.empty?

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
