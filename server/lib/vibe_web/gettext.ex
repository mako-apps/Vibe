defmodule VibeWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://hexdocs.pm/gettext),
  your module is already ready for translations.
  """
  use Gettext, otp_app: :vibe
end
