# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

# minitest-reporters' JUnitReporter writes tests/failures/errors/time onto
# each <testsuite>, but never onto the enclosing <testsuites> root — Codecov
# Test Analytics requires those on the root element too, so copy them up.
desc "Add root-level summary attributes to JUnit XML reports for Codecov Test Analytics"
task :fix_junit_reports do
  require "rexml/document"

  Dir.glob("test/reports/TEST-*.xml").each do |path|
    doc = REXML::Document.new(File.read(path))
    suite = doc.root&.elements&.[]("testsuite")
    next unless suite

    %w[tests failures errors time].each do |attr|
      doc.root.attributes[attr] = suite.attributes[attr]
    end

    File.write(path, doc.to_s)
  end
end

Rake::Task["test"].enhance do
  Rake::Task["fix_junit_reports"].invoke
end

task default: :test
