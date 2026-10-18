import portals


def word_count(text):
    return len(text.split())


def parse_int(text):
    return int(text)  # a ValueError becomes %Portals.Error{kind: :remote}


def progress(steps):
    for step in range(1, steps + 1):
        # Blocks this handler's thread until MyApp.Progress.report/1 returns.
        portals.callback("Elixir.MyApp.Progress", "report", [step])
    return steps


def notify(pid, text):
    portals.send_message(pid, text.upper())  # fire-and-forget
    return "sent"


@portals.stream_handler
def upcase_stream(stream):
    count = 0
    for chunk in stream:  # ends when the BEAM half-closes its side
        stream.send(chunk.upper())  # blocks while the BEAM's credit is used up
        count += 1
    return count  # the stream's final result
