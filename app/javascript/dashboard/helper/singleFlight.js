/**
 * Runs one request per key at a time. A call made while a request with the same key is already
 * running does not start a second request: it joins the running one, and the request is repeated
 * once after it settles, so the joined caller still gets data newer than its call. Any number of
 * overlapping calls therefore cost at most one extra request.
 *
 * @returns {(key: string, run: () => Promise<any>) => Promise<any>}
 */
export const createSingleFlight = () => {
  const flights = new Map();

  return (key, run) => {
    const running = flights.get(key);
    if (running) {
      running.repeat = true;
      return running.promise;
    }

    const flight = { repeat: false, promise: null };
    flight.promise = (async () => {
      try {
        let result = await run();
        while (flight.repeat) {
          flight.repeat = false;
          // eslint-disable-next-line no-await-in-loop
          result = await run();
        }
        return result;
      } finally {
        flights.delete(key);
      }
    })();
    flights.set(key, flight);
    return flight.promise;
  };
};

export default createSingleFlight;
