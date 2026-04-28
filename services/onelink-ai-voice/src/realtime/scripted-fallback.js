class ScriptedFallbackResponder {
  constructor({ message = 'Извините, голосовой ассистент временно недоступен.' } = {}) {
    this.message = message;
  }

  async greet(call) {
    if (call && typeof call.say === 'function') {
      await call.say(this.message);
    }
    return this.message;
  }
}

module.exports = { ScriptedFallbackResponder };
