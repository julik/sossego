# frozen_string_literal: true

class BoardController < ApplicationController
  def show
    %w[Tranquility Calm Peace].each { |name| Counter.find_or_create_by!(name: name) }
    @counters = Counter.order(:id)
    @head = Counter::STREAM.head.to_s
  end

  # Bumps a counter and tells every open board, this one included, through
  # a Turbo Stream published on the board's stream.
  def bump
    counter = Counter.find(params[:id])
    counter.with_lock { counter.update!(value: counter.value + 1) }

    html = render_to_string(turbo_stream: turbo_stream.replace(counter, partial: "board/counter", locals: {counter: counter}))
    Counter::STREAM.publish("turbo_stream", html)
    head :no_content
  end
end
