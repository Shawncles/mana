defmodule EVM.VM do
  @moduledoc """
  The core of the EVM which runs operations based on the
  opcodes of a contract during a transfer or message call.
  """

  alias EVM.{SubState, MachineCode, MachineState, ExecEnv, Functions, Gas, Operation, Debugger}

  @type output :: binary() | :failed

  @doc """
  This function computes the Ξ function Eq.(123) of the Section 9.4 of the Yellow Paper.
  This is the complete result of running a given program in the VM.

  Note: We replace returning state with exec env, which in our implementation contains the world state.

  ## Examples

      # Full program
      iex> EVM.VM.run(24, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:push1, 3, :push1, 5, :add, :push1, 0x00, :mstore, :push1, 32, :push1, 0, :return])})
      {0, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:push1, 3, :push1, 5, :add, :push1, 0x00, :mstore, :push1, 32, :push1, 0, :return])}, <<0x08::256>>}

      # Program with implicit stop
      iex> EVM.VM.run(9, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:push2, 0, 3, :push1, 5, :add])})
      {0, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:push2, 0, 3, :push1, 5, :add])}, ""}

      # Program with explicit stop
      iex> EVM.VM.run(5, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:push1, 3, :stop])})
      {2, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:push1, 3, :stop])}, ""}

      # Program with exception halt
      iex> EVM.VM.run(5, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:add])})
      {5, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:add])}, :failed}
  """
  @spec run(Gas.t(), ExecEnv.t()) :: {Gas.t(), SubState.t(), ExecEnv.t(), output}
  def run(gas, exec_env) do
    machine_state = %MachineState{gas: gas}
    sub_state = %SubState{}

    {n_machine_state, n_sub_state, n_exec_env, output} = exec(machine_state, sub_state, exec_env)

    {n_machine_state.gas, n_sub_state, n_exec_env, output}
  end

  @doc """
  Runs a cycle of our VM in a recursive fashion, defined as `X`, Eq.(131) of the
  Yellow Paper. This function halts when return is called or an exception raised.

  ## Examples

      iex> EVM.VM.exec(%EVM.MachineState{program_counter: 0, gas: 5, stack: [1, 2]}, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:add])})
      {%EVM.MachineState{program_counter: 2, gas: 2, stack: [3], last_return_data: [3]}, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:add])}, ""}

      iex> EVM.VM.exec(%EVM.MachineState{program_counter: 0, gas: 9, stack: []}, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:push1, 3, :push1, 5, :add])})
      {%EVM.MachineState{program_counter: 6, gas: 0, last_return_data: [8], stack: [8]}, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:push1, 3, :push1, 5, :add])}, ""}

      iex> EVM.VM.exec(%EVM.MachineState{program_counter: 0, gas: 24, stack: []}, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:push1, 3, :push1, 5, :add, :push1, 0x00, :mstore, :push1, 32, :push1, 0, :return])})
      {%EVM.MachineState{active_words: 1, last_return_data: [], memory: <<0x08::256>>, gas: 0, program_counter: 13, stack: []}, %EVM.SubState{logs: [], refund: 0}, %EVM.ExecEnv{machine_code: <<96, 3, 96, 5, 1, 96, 0, 82, 96, 32, 96, 0, 243>>}, <<8::256>>}
  """
  @spec exec(MachineState.t(), SubState.t(), ExecEnv.t()) ::
          {MachineState.t(), SubState.t(), ExecEnv.t(), output}
  def exec(machine_state, sub_state, exec_env) do
    do_exec(machine_state, sub_state, exec_env, {machine_state, sub_state, exec_env})
  end

  @spec do_exec(
          MachineState.t(),
          SubState.t(),
          ExecEnv.t(),
          {MachineState.t(), SubState.t(), ExecEnv.t()}
        ) :: {MachineState.t(), SubState.t(), ExecEnv.t(), output}
  defp do_exec(
         machine_state,
         sub_state,
         exec_env,
         {original_machine_state, original_sub_state, original_exec_env}
       ) do
    # Debugger generally runs here.
    {machine_state, sub_state, exec_env} =
      if Debugger.enabled?() do
        case Debugger.is_breakpoint?(machine_state, sub_state, exec_env) do
          :continue ->
            {machine_state, sub_state, exec_env}

          breakpoint ->
            Debugger.break(breakpoint, machine_state, sub_state, exec_env)
        end
      else
        {machine_state, sub_state, exec_env}
      end

    case Functions.is_exception_halt?(machine_state, exec_env) do
      {:halt, _reason} ->
        # We're exception halting, undo it all.
        # Question: should we return the original sub-state?
        {original_machine_state, original_sub_state, original_exec_env, :failed}

      :continue ->
        {n_machine_state, n_sub_state, n_exec_env} = cycle(machine_state, sub_state, exec_env)

        case Functions.is_normal_halting?(machine_state, exec_env) do
          # continue execution
          nil ->
            do_exec(
              n_machine_state,
              n_sub_state,
              n_exec_env,
              {original_machine_state, original_sub_state, original_exec_env}
            )

          # revert state and return
          {:revert, output} ->
            {n_machine_state, original_sub_state, original_exec_env, output}

          # break execution and return
          output ->
            {n_machine_state, n_sub_state, n_exec_env, output}
        end
    end
  end

  @doc """
  Runs a single cycle of our VM returning the new state,
  defined as `O` in the Yellow Paper, Eq.(143).

  ## Examples

      iex> EVM.VM.cycle(%EVM.MachineState{program_counter: 0, gas: 5, stack: [1, 2]}, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:add])})
      {%EVM.MachineState{program_counter: 1, last_return_data: [3], gas: 2, stack: [3]}, %EVM.SubState{}, %EVM.ExecEnv{machine_code: EVM.MachineCode.compile([:add])}}
  """
  @spec cycle(MachineState.t(), SubState.t(), ExecEnv.t()) ::
          {MachineState.t(), SubState.t(), ExecEnv.t()}
  def cycle(machine_state, sub_state, exec_env) do
    operation = MachineCode.current_operation(machine_state, exec_env)
    inputs = Operation.inputs(operation, machine_state)

    machine_state = MachineState.subtract_gas(machine_state, exec_env)
    sub_state = SubState.add_refund(machine_state, sub_state, exec_env)

    {n_machine_state, n_sub_state, n_exec_env} =
      Operation.run(operation, machine_state, sub_state, exec_env)

    final_machine_state = MachineState.move_program_counter(n_machine_state, operation, inputs)

    {final_machine_state, n_sub_state, n_exec_env}
  end
end
