/******************************************************************************/
/*                                                                            */
/* SPDX-License-Identifier: MIT                                               */
/* Copyright (c) [2023] Serokell <hi@serokell.io>                             */
/*                                                                            */
/******************************************************************************/

use crate::ast::*;
use crate::gas;
use crate::gas::{Gas, OutOfGas};
use crate::stack::*;
use std::collections::VecDeque;

/// Typechecker error type.
#[derive(Debug, PartialEq, Eq)]
pub enum TcError {
    GenericTcError,
    StackTooShort,
    StacksNotEqual,
    OutOfGas,
}

impl From<OutOfGas> for TcError {
    fn from(_: OutOfGas) -> Self {
        TcError::OutOfGas
    }
}

pub fn typecheck(ast: &AST, gas: &mut Gas, stack: &mut TypeStack) -> Result<(), TcError> {
    for i in ast {
        typecheck_instruction(&i, gas, stack)?;
    }
    Ok(())
}

fn typecheck_instruction(
    i: &Instruction,
    gas: &mut Gas,
    stack: &mut TypeStack,
) -> Result<(), TcError> {
    use Instruction::*;
    use Type::*;

    gas.consume(gas::tc_cost::INSTR_STEP)?;

    match i {
        Add => match stack.make_contiguous() {
            [Type::Nat, Type::Nat, ..] => {
                stack.pop_front();
            }
            [Type::Int, Type::Int, ..] => {
                stack.pop_front();
            }
            _ => unimplemented!(),
        },
        Dip(opt_height, nested) => {
            let protected_height: usize = opt_height.unwrap_or(1);

            gas.consume(gas::tc_cost::dip_n(opt_height)?)?;

            ensure_stack_len(stack, protected_height)?;
            // Here we split the stack into protected and live segments, and after typechecking
            // nested code with the live segment, we append the protected and the potentially
            // modified live segment as the result stack.
            let mut live = stack.split_off(protected_height);
            typecheck(nested, gas, &mut live)?;
            stack.append(&mut live);
        }
        Drop(opt_height) => {
            let drop_height: usize = opt_height.unwrap_or(1);
            gas.consume(gas::tc_cost::drop_n(opt_height)?)?;
            ensure_stack_len(&stack, drop_height)?;
            *stack = stack.split_off(drop_height);
        }
        Dup(Some(0)) => {
            // DUP instruction requires an argument that is > 0.
            return Err(TcError::GenericTcError);
        }
        Dup(opt_height) => {
            let dup_height: usize = opt_height.unwrap_or(1);
            ensure_stack_len(stack, dup_height)?;
            stack.push_front(stack.get(dup_height - 1).unwrap().to_owned());
        }
        Gt => match stack.make_contiguous() {
            [Type::Int, ..] => {
                stack[0] = Type::Bool;
            }
            _ => return Err(TcError::GenericTcError),
        },
        If(nested_t, nested_f) => match stack.make_contiguous() {
            // Check if top is bool and bind the tail to `t`.
            [Type::Bool, t @ ..] => {
                // Clone the stack so that we have two stacks to run
                // the two branches with.
                let mut t_stack: TypeStack = VecDeque::from(t.to_owned());
                let mut f_stack: TypeStack = VecDeque::from(t.to_owned());
                typecheck(nested_t, gas, &mut t_stack)?;
                typecheck(nested_f, gas, &mut f_stack)?;
                // If both stacks are same after typecheck, then make result
                // stack using one of them and return success.
                ensure_stacks_eq(gas, t_stack.make_contiguous(), f_stack.make_contiguous())?;
                *stack = t_stack;
            }
            _ => return Err(TcError::GenericTcError),
        },
        Instruction::Int => match stack.make_contiguous() {
            [val @ Type::Nat, ..] => {
                *val = Type::Int;
            }
            _ => return Err(TcError::GenericTcError),
        },
        Loop(nested) => match stack.make_contiguous() {
            // Check if top is bool and bind the tail to `t`.
            [Bool, t @ ..] => {
                let mut live: TypeStack = VecDeque::from(t.to_owned());
                // Clone the tail and typecheck the nested body using it.
                typecheck(nested, gas, &mut live)?;
                // If the starting stack and result stack match
                // then the typecheck is complete. pop the bool
                // off the original stack to form the final result.
                ensure_stacks_eq(gas, live.make_contiguous(), stack.make_contiguous())?;
                stack.pop_front();
            }
            _ => return Err(TcError::GenericTcError),
        },
        Push(t, v) => {
            typecheck_value(gas, &t, &v)?;
            stack.push_front(t.to_owned());
        }
        Swap => {
            ensure_stack_len(stack, 2)?;
            stack.swap(0, 1);
        }
    }
    Ok(())
}

fn typecheck_value(gas: &mut Gas, t: &Type, v: &Value) -> Result<(), TcError> {
    use Type::*;
    use Value::*;
    gas.consume(gas::tc_cost::VALUE_STEP)?;
    match (t, v) {
        (Nat, NumberValue(n)) if *n >= 0 => Ok(()),
        (Int, NumberValue(_)) => Ok(()),
        (Bool, BooleanValue(_)) => Ok(()),
        _ => Err(TcError::GenericTcError),
    }
}

#[cfg(test)]
mod typecheck_tests {
    use std::collections::VecDeque;

    use crate::parser::*;
    use crate::typechecker::*;
    use Instruction::*;

    #[test]
    fn test_dup() {
        let mut stack = VecDeque::from([Type::Nat]);
        let expected_stack = VecDeque::from([Type::Nat, Type::Nat]);
        let mut gas = Gas::new(10000);
        typecheck_instruction(&Dup(Some(1)), &mut gas, &mut stack).unwrap();
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440);
    }

    #[test]
    fn test_dup_n() {
        let mut stack = VecDeque::from([Type::Nat, Type::Int]);
        let expected_stack = VecDeque::from([Type::Int, Type::Nat, Type::Int]);
        let mut gas = Gas::new(10000);
        typecheck_instruction(&Dup(Some(2)), &mut gas, &mut stack).unwrap();
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440);
    }

    #[test]
    fn test_swap() {
        let mut stack = VecDeque::from([Type::Nat, Type::Int]);
        let expected_stack = VecDeque::from([Type::Int, Type::Nat]);
        let mut gas = Gas::new(10000);
        typecheck_instruction(&Swap, &mut gas, &mut stack).unwrap();
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440);
    }

    #[test]
    fn test_int() {
        let mut stack = VecDeque::from([Type::Nat]);
        let expected_stack = VecDeque::from([Type::Int]);
        let mut gas = Gas::new(10000);
        typecheck_instruction(&Int, &mut gas, &mut stack).unwrap();
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440);
    }

    #[test]
    fn test_drop() {
        let mut stack = VecDeque::from([Type::Nat]);
        let expected_stack = VecDeque::from([]);
        let mut gas = Gas::new(10000);
        typecheck(&parse("{DROP}").unwrap(), &mut gas, &mut stack).unwrap();
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440);
    }

    #[test]
    fn test_drop_n() {
        let mut stack = VecDeque::from([Type::Nat, Type::Int]);
        let expected_stack = VecDeque::from([]);
        let mut gas = Gas::new(10000);
        typecheck_instruction(&Drop(Some(2)), &mut gas, &mut stack).unwrap();
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440 - 2 * 50);
    }

    #[test]
    fn test_push() {
        let mut stack = VecDeque::from([Type::Nat]);
        let expected_stack = VecDeque::from([Type::Int, Type::Nat]);
        let mut gas = Gas::new(10000);
        typecheck_instruction(
            &Push(Type::Int, Value::NumberValue(1)),
            &mut gas,
            &mut stack,
        )
        .unwrap();
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440 - 100);
    }

    #[test]
    fn test_gt() {
        let mut stack = VecDeque::from([Type::Int]);
        let expected_stack = VecDeque::from([Type::Bool]);
        let mut gas = Gas::new(10000);
        typecheck_instruction(&Gt, &mut gas, &mut stack).unwrap();
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440);
    }

    #[test]
    fn test_dip() {
        let mut stack = VecDeque::from([Type::Int, Type::Bool]);
        let expected_stack = VecDeque::from([Type::Int, Type::Nat, Type::Bool]);
        let mut gas = Gas::new(10000);
        typecheck_instruction(
            &Dip(Some(1), parse("{PUSH nat 6}").unwrap()),
            &mut gas,
            &mut stack,
        )
        .unwrap();
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440 - 440 - 100 - 50);
    }

    #[test]
    fn test_add() {
        let mut stack = VecDeque::from([Type::Int, Type::Int]);
        let expected_stack = VecDeque::from([Type::Int]);
        let mut gas = Gas::new(10000);
        typecheck_instruction(&Add, &mut gas, &mut stack).unwrap();
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440);
    }

    #[test]
    fn test_loop() {
        let mut stack = VecDeque::from([Type::Bool, Type::Int]);
        let expected_stack = VecDeque::from([Type::Int]);
        let mut gas = Gas::new(10000);
        assert!(typecheck_instruction(
            &Loop(parse("{PUSH bool True}").unwrap()),
            &mut gas,
            &mut stack
        )
        .is_ok());
        assert!(stack == expected_stack);
        assert!(gas.milligas() == 10000 - 440 - 440 - 100 - 60 * 2);
    }

    #[test]
    fn test_loop_stacks_not_equal_length() {
        let mut stack = VecDeque::from([Type::Bool, Type::Int]);
        let mut gas = Gas::new(10000);
        assert!(
            typecheck_instruction(
                &Loop(parse("{PUSH int 1; PUSH bool True}").unwrap()),
                &mut gas,
                &mut stack
            ) == Err(TcError::StacksNotEqual)
        );
    }

    #[test]
    fn test_loop_stacks_not_equal_types() {
        let mut stack = VecDeque::from([Type::Bool, Type::Int]);
        let mut gas = Gas::new(10000);
        assert!(
            typecheck_instruction(
                &Loop(parse("{DROP; PUSH bool False; PUSH bool True}").unwrap()),
                &mut gas,
                &mut stack
            ) == Err(TcError::StacksNotEqual)
        );
    }
}
