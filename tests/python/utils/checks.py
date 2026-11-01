"""Verificações compartilhadas pelos testes."""


def check(condition: bool, message: str) -> None:
    """Raise AssertionError with the message when condition is false.

    Parameters
    ----------
    condition : bool
        Value that must hold.
    message : str
        Text of the error raised when the condition is false.

    Raises
    ------
    AssertionError
        If the condition is false.
    """
    if not condition:
        raise AssertionError(message)
