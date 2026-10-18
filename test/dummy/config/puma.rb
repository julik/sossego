# frozen_string_literal: true

# Every open stream holds a thread for up to 30 seconds. The demos open a
# few per tab.
threads 32, 32
port ENV.fetch("PORT", 3000)
