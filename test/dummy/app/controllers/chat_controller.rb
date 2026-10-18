# frozen_string_literal: true

class ChatController < ApplicationController
  STREAM = Sossego::Stream.new("demo:1:chat")

  def show
    # Where the page's data stops: the stream connects from here, so
    # nothing published after the render is missed and nothing before is
    # replayed twice.
    @head = STREAM.head.to_s
    @messages = Sossego::Event.for_stream(STREAM.id).where(event_name: "chat_message").order(id: :desc).limit(20).reverse
  end

  def create
    STREAM.publish("chat_message", {author: params[:author].presence || "anonymous", text: params[:text].to_s.truncate(2_000)})
    head :no_content
  end

  def close_stream
    STREAM.publish_close(reason: "closed_by_#{params[:author].presence || "someone"}")
    head :no_content
  end
end
