# frozen_string_literal: true

# Opens N SSE connections and reports, once a second, the frames they got and
# how long one published event took to reach every connection. Needs falcon
# (for async-http) in the bundle. See config.ru next to this file.
$stdout.sync = true
require "async"
require "async/barrier"
require "async/http/internet"

N = Integer(ARGV[0] || 1000)
URL = ARGV[1] || "http://127.0.0.1:3777/board/stream"
RAMP = Integer(ARGV[2] || 250)

connected = 0
closed = 0
frames = Hash.new(0)
arrivals = Hash.new { |h, k| h[k] = [] }
errors = Hash.new(0)
now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
started = now.call

Async do |task|
  internet = Async::HTTP::Internet.new
  barrier = Async::Barrier.new
  reporter = task.async do
    loop do
      sleep 1
      spread = arrivals.to_a.last(4).map { |id, ts| "#{id}:#{ts.size}/#{((ts.max - ts.min) * 1000).round}ms" }.join(" ")
      puts format("t=%3.0fs open=%d closed=%d frames=%s events=[%s] errors=%s", now.call - started, connected - closed, closed, frames.to_h.inspect, spread, errors.inspect)
    end
  end

  N.times do |i|
    barrier.async do
      response = internet.get(URL, {"accept" => "text/event-stream"})
      if response.status != 200
        errors["status #{response.status}"] += 1
        response.close
        next
      end
      connected += 1
      buffer = +""
      response.body.each do |chunk|
        buffer << chunk
        while (idx = buffer.index("\n\n"))
          frame = buffer.slice!(0, idx + 2)
          ev = frame[/^event: (\w+)/, 1] || "retry"
          frames[ev] += 1
          if ev == "sossego" && (id = frame[/^id: (\d+)/, 1])
            arrivals[id] << now.call
          end
        end
      end
      closed += 1
    rescue => e
      errors["#{e.class}: #{e.message[0, 50]}"] += 1
    end
    sleep(0.05) if (i % RAMP) == RAMP - 1
  end
  barrier.wait
  reporter.stop
  puts "done: #{frames.to_h.inspect} errors=#{errors.inspect}"
end
