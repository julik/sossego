class CreateSossegoEvents < ActiveRecord::Migration[8.1]
  def change
    # The integer `id` is the cursor: global across streams, and increasing in
    # commit order within a stream because Sossego::Event.publish holds the
    # stream's lock while it inserts. Surfaced to the client as the SSE `id:`
    # field (a string) and echoed back as `Last-Event-ID` on reconnect. Never
    # reused (bigserial on PostgreSQL, AUTOINCREMENT on SQLite), so a stream
    # pruned empty resumes correctly.
    create_table :sossego_events do |t|
      # Stream identifier like "account:42:inbox". See Sossego::Stream.
      t.string :stream_id, null: false

      # Per-stream sequence, dense among retained rows, starting at 1.
      # Assigned as MAX(sseq) + 1 under the publish lock. Used for gap
      # detection and conditional appends (`after:`), never as a cursor.
      t.bigint :sseq, null: false

      # The application's event name, or "close" when written by
      # Sossego::Stream#publish_close.
      t.string :event_name, null: false

      # JSON text of the payload. Never queried into.
      t.text :payload, null: false

      t.datetime :created_at, null: false
    end

    # The poll: events of one stream after a cursor.
    add_index :sossego_events, [:stream_id, :id]

    # A guard against a writer that bypassed the publish lock.
    add_index :sossego_events, [:stream_id, :sseq], unique: true

    # Retention, see Sossego::PruneJob.
    add_index :sossego_events, :created_at
  end
end
