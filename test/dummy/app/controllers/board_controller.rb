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

    Counter::STREAM.publish_turbo_stream(:replace, target: counter, partial: "board/counter", locals: {counter: counter})
    head :no_content
  end
end
