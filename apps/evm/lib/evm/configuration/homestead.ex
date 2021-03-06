defmodule EVM.Configuration.Homestead do
  defstruct contract_creation_cost: 53_000, has_delegate_call: true

  def new do
    %__MODULE__{}
  end
end

defimpl EVM.Configuration, for: EVM.Configuration.Homestead do
  @spec contract_creation_cost(EVM.Configuration.t()) :: integer()
  def contract_creation_cost(config), do: config.contract_creation_cost

  @spec has_delegate_call?(EVM.Configuration.t()) :: boolean()
  def has_delegate_call?(config), do: config.has_delegate_call
end
