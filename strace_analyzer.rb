#!/usr/bin/env ruby

class FileRecord
  attr_accessor :pid, :fd, :name, :write_time, :write_bytes, :read_time, :read_bytes

  def initialize(pid, fd, name)
    @pid = pid
    @fd = fd
    @name = name
    @read_time = @read_bytes = @write_time = @write_bytes = 0
    puts "Open: #{pid} #{fd} #{name}"
  end

  def to_s
    "#{pid} #{fd} #{name} #{write_time} #{write_bytes} #{read_time} #{read_bytes}"
  end
end

class StraceAnalyzer
  attr_accessor :open_files
  attr_accessor :closed_files
  attr_accessor :thread_map

  def initialize
    @intr_calls = {}
    @open_files = {} # Key = "#{pid}:#{fd}"
    @closed_files = []
    @thread_map = {} # thread_id => pid
  end

  def analyze(thread_or_pid, call, args, result, duration)
    #puts "#{pid}, #{call}, = #{result}, #{duration}, #{args}"
    pid = @thread_map[thread_or_pid] || thread_or_pid
    case call
    when "clone"
      thread_id = result.to_i
      if args.match(/CLONE_FILES/)
        @thread_map[thread_id] = pid
        puts "Clone files: #{pid} => #{thread_id}"
      else
        @open_files.keys.each do |key|
          child_pid = result.to_i
          parent_pid, parent_fd = key.split(':')
          if parent_pid.to_i == pid.to_i
            child_key = "#{child_pid}:#{parent_fd}"
            @open_files[child_key] = @open_files[key]
          end
        end
      end
    when "open","creat"
      fd = result.to_i
      if (fd > 0 && args.match(/\"(.*)\"/))
        path = $1
        key = "#{pid}:#{fd}"
        @open_files[key] = FileRecord.new(pid, fd, path)
        #puts "Open #{key.inspect}, #{args.inspect}"
      end
    when "openat"
      fd = result.to_i
      if (fd > 0)
        key = "#{pid}:#{fd}"
        file = args.split[1]
        @open_files[key] = FileRecord.new(pid, fd, file)
        #puts "openat #{key.inspect}, #{file}"
      end
    when "accept"
      fd = result.to_i
      if (fd > 0)
        key = "#{pid}:#{fd}"
        socket = args.split[0]
        @open_files[key] = FileRecord.new(pid, fd, "socket_#{socket}")
        #puts "socket #{key.inspect}, #{socket}"
      end
    when "socketpair"
      if args.match(/\[(.*)\]/)
        fds = $1.split(", ")
        fds.each do |fd|
          key = "#{pid}:#{fd}"
          @open_files[key] = FileRecord.new(pid, fd, "socket_#{fd}")
          #puts "socket #{key.inspect}, #{fd}"
        end
      end
    when "pipe"
      if args.match(/\[(.*)\]/)
        fds = $1.split(", ")
        fds.each do |fd|
          key = "#{pid}:#{fd}"
          @open_files[key] = FileRecord.new(pid, fd, "pipe_#{fd}")
          #puts "pipe #{key.inspect}, #{fd}"
        end
      end
    when "read"
      fd = args.split[0].to_i
      return if fd == 255 || fd == 0
      key = "#{pid}:#{fd}"
      bytes = result.to_i
      file_record = @open_files[key]
      if file_record
        file_record.read_bytes += bytes
        file_record.read_time += duration.to_f 
        #puts "read: #{file_record.name}: #{args}"
      else
        puts "#{thread_or_pid} - Read error, no record for #{key}"
        exit 1
      end
    when "write"
      fd = args.split[0].to_i
      return if fd == 255 || fd < 3
      key = "#{pid}:#{fd}"
      bytes = result.to_i
      file_record = @open_files[key]
      if file_record
        file_record.write_bytes += bytes
        file_record.write_time += duration.to_f 
        #puts "read: #{file_record.name}: #{args}"
      else
        puts "#{thread_or_pid} - Write error, no record for #{key}"
        exit 1
      end
    when "close"
      fd = args.to_i
      key = "#{pid}:#{fd}"
      file_record = @open_files[key]
      if file_record
        puts "Closing #{file_record}"
        @closed_files << file_record
      else
        #puts "Error closing, no record for #{key}"
        #exit 1
      end
      @open_files.delete(key)
    end

  end

  def add_line(line)
    case line
    when /(\d+)  ([\d\.]+) (\w+)\((.*)\) += +(.*) <([\d\.]+)>/
      pid = $1
      call = $3
      args = $4
      result = $5
      duration = $6
      analyze(pid.to_i, call, args, result, duration)
    when /(\d+)  ([\d\.]+) (\w+)\((.*)  ?<unfinished/
      pid = $1
      call = $3
      args = $4
      @intr_calls[pid] = args
      #puts "intr #{pid} = #{args}"
    when /(\d+)  ([\d\.]+) <\.\.\. (.*) resumed> (.*)\) = (.*) <([\d\.]+)>/
      pid = $1
      if @intr_calls[pid].nil?
        puts "Unmatched resumed call for pid #{pid}: #{line}"
        exit 1
      end
      call = $3
      args = @intr_calls[pid] + $4
      @intr_calls[pid] = nil
      result = $5
      duration = $6
      analyze(pid.to_i, call, args, result, duration)
    else
      #puts "***********: #{line.inspect}"
    end 
  end

end

analyzer = StraceAnalyzer.new

while(line = STDIN.gets)
  analyzer.add_line(line)
end

all_files = analyzer.open_files.values + analyzer.closed_files

all_files.sort_by(&:write_time).reverse[0,10].each do |file|
  puts "topten write: #{file}"
end

all_files.sort_by(&:read_time).reverse[0,10].each do |file|
  puts "topten read: #{file}"
end
