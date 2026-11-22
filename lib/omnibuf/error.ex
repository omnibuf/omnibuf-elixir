defmodule OmniBuf.Error do
  @moduledoc """
  Exception struct representing OmniBuf wire decoding, validation, or encoding errors.
  """

  defexception [:reason, :message]

  @type t :: %__MODULE__{
          reason: atom(),
          message: String.t()
        }

  @spec new(atom(), String.t()) :: t()
  def new(reason, message) when is_atom(reason) and is_binary(message) do
    %__MODULE__{reason: reason, message: message}
  end

  @spec parse(atom(), String.t()) :: {:error, t()}
  def parse(reason, message) do
    {:error, new(reason, message)}
  end
end
