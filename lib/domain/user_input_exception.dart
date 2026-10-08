/// A deliberate input rejection with a message suitable for display.
/// Parser exceptions may contain input data and must use a fixed fallback.
class UserInputException extends FormatException {
  const UserInputException(super.message);
}
