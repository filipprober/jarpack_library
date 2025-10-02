#!/usr/bin/env ruby
# Java Package Validator - Prüft Package-Namen vs. Verzeichnisstruktur

require 'pathname'

class JavaPackageValidator
  def initialize(src_directory = 'src', expected_prefix = nil)
    @src_directory = src_directory
    @expected_prefix = expected_prefix
    @errors = []
    @warnings = []
    @checked_files = 0
  end

  def validate!
    puts "🔍 Scanning Java files in #{@src_directory}..."

    unless Dir.exist?(@src_directory)
      puts "❌ Source directory '#{@src_directory}' not found!"
      return false
    end

    java_files = Dir.glob("#{@src_directory}/**/*.{java,kt}")

    if java_files.empty?
      puts "⚠️  No Java/Kotlin files found in #{@src_directory}"
      return true
    end

    java_files.each { |file| validate_file(file) }

    print_summary
    @errors.empty?
  end

  private

  def validate_file(file_path)
    @checked_files += 1

    # Package-Deklaration aus File lesen
    actual_package = extract_package_from_file(file_path)

    # Wenn ein Prefix gesetzt ist, muss eine Package-Deklaration vorhanden sein
    if @expected_prefix && (actual_package.nil? || actual_package.empty?)
      @errors << "❌ #{file_path}: Missing package declaration! Expected package starting with '#{@expected_prefix}'"
      return
    end

    # Erwartetes Package aus Pfad ableiten
    relative_path = file_path.sub(%r{^#{Regexp.escape(@src_directory)}/}, '')
    path_package = File.dirname(relative_path).gsub('/', '.')
    path_package = '' if path_package == '.'

    # Wenn ein Prefix gesetzt ist und die Datei im src-Root liegt,
    # dann ist das erwartete Package mindestens der Prefix
    expected_package = if @expected_prefix && path_package.empty?
                         @expected_prefix
                       elsif @expected_prefix && !path_package.empty?
                         "#{@expected_prefix}.#{path_package}"
                       else
                         path_package
                       end

    # Validierungen
    validate_package_consistency(file_path, expected_package, actual_package)
    validate_package_prefix(file_path, actual_package) if @expected_prefix
  end

  def extract_package_from_file(file_path)
    begin
      content = File.read(file_path, encoding: 'UTF-8')
    rescue StandardError => e
      @errors << "❌ Cannot read file #{file_path}: #{e.message}"
      return nil
    end

    # Package-Deklaration finden (ignoriert Kommentare)
    lines = content.lines
    package_lines = lines.reject { |line| line.strip.start_with?('//') || line.strip.start_with?('/*') }
                         .grep(/^\s*package\s+/)

    case package_lines.size
    when 0
      '' # Default package
    when 1
      # Kotlin: package abc.def (ohne Semikolon)
      # Java:   package abc.def; (mit Semikolon)
      match = if file_path.end_with?('.kt')
                package_lines.first.match(/^\s*package\s+([a-zA-Z0-9_.]+)/)
              else
                package_lines.first.match(/^\s*package\s+([a-zA-Z0-9_.]+)\s*;/)
              end
      match ? match[1] : nil
    else
      @errors << "❌ #{file_path}: Multiple package declarations found"
      nil
    end
  end

  def validate_package_consistency(file_path, expected_package, actual_package)
    return if actual_package.nil? # Bereits als Fehler erfasst

    # Wenn ein Prefix gesetzt ist, prüfe nur ob das Package damit beginnt
    if @expected_prefix
      # Package muss entweder exakt dem Prefix entsprechen oder mit Prefix + '.' beginnen
      valid = actual_package == @expected_prefix || actual_package.start_with?(@expected_prefix + '.')
      return if valid

      @errors << "❌ #{file_path}:"
      @errors << "   Expected: package starting with #{@expected_prefix};"
      @errors << "   Found:    package #{actual_package.empty? ? '(default)' : actual_package};"
    else
      # Ohne Prefix: exaktes Match erforderlich
      return unless expected_package != actual_package

      @errors << "❌ #{file_path}:"
      @errors << "   Expected: package #{expected_package.empty? ? '(default)' : expected_package};"
      @errors << "   Found:    package #{actual_package.empty? ? '(default)' : actual_package};"
    end
  end

  def validate_package_prefix(file_path, actual_package)
    return if actual_package.nil? || actual_package.empty?

    return if actual_package.start_with?(@expected_prefix)

    @warnings << "⚠️  #{file_path}: Package '#{actual_package}' doesn't start with '#{@expected_prefix}'"
  end

  def print_summary
    puts "\n" + '=' * 60
    puts '📊 VALIDATION SUMMARY'
    puts '=' * 60
    puts "Files checked: #{@checked_files}"
    puts "Errors: #{@errors.size}"
    puts "Warnings: #{@warnings.size}"

    if @errors.any?
      puts "\n🚨 ERRORS:"
      @errors.each { |error| puts error }
    end

    if @warnings.any?
      puts "\n⚠️  WARNINGS:"
      @warnings.each { |warning| puts warning }
    end

    puts "\n✅ All files passed validation!" if @errors.empty? && @warnings.empty?

    puts '=' * 60
  end
end

# CLI Interface
if __FILE__ == $0
  require 'optparse'

  options = {
    src_dir: 'src',
    prefix: 'com.example'
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [options]"

    opts.on('-s', '--src DIR', 'Source directory (default: src)') do |dir|
      options[:src_dir] = dir
    end

    opts.on('-p', '--prefix PREFIX', 'Expected package prefix (e.g., vendor.package)') do |prefix|
      options[:prefix] = prefix
    end

    opts.on('-h', '--help', 'Show this help') do
      puts opts
      exit
    end
  end.parse!

  validator = JavaPackageValidator.new(options[:src_dir], options[:prefix])
  success = validator.validate!

  exit(success ? 0 : 1)
end
