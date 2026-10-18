# frozen_string_literal: true

class Counter < ApplicationRecord
  STREAM = Sossego::Stream.new("demo:1:board")
end
