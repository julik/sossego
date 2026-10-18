# frozen_string_literal: true

Rails.application.routes.draw do
  mount Sossego::Engine => "/sossego"

  root "demos#index"

  # A task with a progress display, on a signed random stream
  get "progress" => "progress#new", :as => :progress
  post "progress/analyze" => "progress#analyze", :as => :analyze_progress
  post "progress/prepare" => "progress#prepare", :as => :prepare_progress
  get "progress/preparing" => "progress#preparing", :as => :preparing_progress
  get "progress/prepared" => "progress#prepared", :as => :prepared_progress

  # The plain JS client on a shared stream
  get "chat" => "chat#show", :as => :chat
  post "chat/messages" => "chat#create", :as => :chat_messages
  post "chat/close" => "chat#close_stream", :as => :close_chat
  get "chat/stream" => "chat_streams#show", :as => :chat_stream

  # Turbo Streams over Sossego
  get "board" => "board#show", :as => :board
  post "board/counters/:id/bump" => "board#bump", :as => :bump_counter
  get "board/stream" => "board_streams#show", :as => :board_stream
end
