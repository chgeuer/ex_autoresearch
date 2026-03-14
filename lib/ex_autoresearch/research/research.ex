defmodule ExAutoresearch.Research do
  use Ash.Domain

  resources do
    resource ExAutoresearch.Research.Campaign
    resource ExAutoresearch.Research.Trial
  end
end
