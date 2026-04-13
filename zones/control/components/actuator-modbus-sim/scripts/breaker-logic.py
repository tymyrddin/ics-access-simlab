def set_initial(resources):
    resources.get("breaker_state").set_value(1)   # start closed
    resources.get("trip_command").set_value(0)
    resources.get("close_command").set_value(0)


def update_values(resources):
    trip  = resources.get("trip_command")
    close = resources.get("close_command")
    state = resources.get("breaker_state")
    if trip.get_value():
        state.set_value(0)
        trip.set_value(0)
    if close.get_value():
        state.set_value(1)
        close.set_value(0)
