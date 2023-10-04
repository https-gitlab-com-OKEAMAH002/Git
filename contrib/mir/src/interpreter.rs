/******************************************************************************/
/*                                                                            */
/* SPDX-License-Identifier: MIT                                               */
/* Copyright (c) [2023] Serokell <hi@serokell.io>                             */
/*                                                                            */
/******************************************************************************/

use crate::ast::*;
use crate::gas::{interpret_cost, Gas, OutOfGas};
use crate::stack::*;

#[derive(Debug, PartialEq, Eq)]
pub enum InterpretError {
    OutOfGas,
}

impl From<OutOfGas> for InterpretError {
    fn from(_: OutOfGas) -> Self {
        InterpretError::OutOfGas
    }
}

pub fn interpret(ast: &AST, gas: &mut Gas, stack: &mut IStack) -> Result<(), InterpretError> {
    for i in ast {
        interpret_one(&i, gas, stack)?;
    }
    gas.consume(interpret_cost::INTERPRET_RET)?;
    Ok(())
}

fn unreachable_state() -> ! {
    // If the typechecking of the program being interpreted was successful and if this is reached
    // during interpreting, then the typechecking should be broken, and needs to be fixed.
    panic!("Unreachable state reached during interpreting, possibly broken typechecking!")
}

fn interpret_one(i: &Instruction, gas: &mut Gas, stack: &mut IStack) -> Result<(), InterpretError> {
    use Instruction::*;
    use Value::*;

    match i {
        Add => match stack.make_contiguous() {
            [NumberValue(o1), NumberValue(o2), ..] => {
                gas.consume(interpret_cost::add_int(*o1, *o2)?)?;
                let sum = *o1 + *o2;
                stack.pop_front();
                stack.pop_front();
                stack.push_front(NumberValue(sum));
            }
            _ => unimplemented!(),
        },
        Dip(opt_height, nested) => {
            gas.consume(interpret_cost::dip(*opt_height)?)?;
            let protected_height: usize = opt_height.unwrap_or(1);
            let mut live = stack.split_off(protected_height);
            interpret(nested, gas, &mut live)?;
            gas.consume(interpret_cost::undip(protected_height)?)?;
            stack.append(&mut live);
        }
        Drop(opt_height) => {
            gas.consume(interpret_cost::drop(*opt_height)?)?;
            let drop_height: usize = opt_height.unwrap_or(1);
            *stack = stack.split_off(drop_height);
        }
        Dup(opt_height) => {
            gas.consume(interpret_cost::dup(*opt_height)?)?;
            let dup_height: usize = opt_height.unwrap_or(1);
            stack.push_front(stack.get(dup_height - 1).unwrap().clone());
        }
        Gt => {
            gas.consume(interpret_cost::GT)?;
            match stack.make_contiguous() {
                [NumberValue(i), ..] => {
                    stack[0] = BooleanValue(*i > 0);
                }
                _ => unreachable_state(),
            }
        }
        If(nested_t, nested_f) => {
            gas.consume(interpret_cost::IF)?;
            if let Some(BooleanValue(b)) = stack.pop_front() {
                if b {
                    interpret(nested_t, gas, stack)?;
                } else {
                    interpret(nested_f, gas, stack)?;
                }
            } else {
                unreachable_state();
            }
        }
        Instruction::Int => match stack.make_contiguous() {
            [NumberValue(_), ..] => gas.consume(interpret_cost::INT_NAT)?,
            _ => {
                unreachable_state();
            }
        },
        Loop(nested) => {
            gas.consume(interpret_cost::LOOP_ENTER)?;
            loop {
                gas.consume(interpret_cost::LOOP)?;
                if let Some(BooleanValue(b)) = stack.pop_front() {
                    if b {
                        interpret(nested, gas, stack)?;
                    } else {
                        gas.consume(interpret_cost::LOOP_EXIT)?;
                        break;
                    }
                } else {
                    unreachable_state();
                }
            }
        }
        Push(_, v) => {
            gas.consume(interpret_cost::PUSH)?;
            stack.push_front(v.clone());
        }
        Swap => {
            gas.consume(interpret_cost::SWAP)?;
            stack.swap(0, 1);
        }
    }
    Ok(())
}

#[cfg(test)]
mod interpreter_tests {
    use crate::interpreter::*;
    use crate::parser::*;
    use std::collections::VecDeque;
    use Instruction::*;
    use Value::*;

    #[test]
    fn test_add() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(30)]);
        let mut gas = Gas::default();
        assert!(interpret_one(&Add, &mut gas, &mut stack).is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_dip() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(5), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(10), NumberValue(25)]);
        let mut gas = Gas::default();
        assert!(interpret_one(&Dip(None, parse("{ADD}").unwrap()), &mut gas, &mut stack).is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_dip2() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(5), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(10), NumberValue(5)]);
        let mut gas = Gas::default();
        assert!(interpret_one(
            &Dip(Some(2), parse("{DROP}").unwrap()),
            &mut gas,
            &mut stack,
        )
        .is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_drop() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(5), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(5), NumberValue(20)]);
        let mut gas = Gas::default();
        assert!(interpret_one(&Drop(None), &mut gas, &mut stack).is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_drop2() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(5), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(20)]);
        let mut gas = Gas::default();
        assert!(interpret_one(&Drop(Some(2)), &mut gas, &mut stack).is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_dup() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(5), NumberValue(20)]);
        let expected_stack = VecDeque::from([
            NumberValue(10),
            NumberValue(10),
            NumberValue(5),
            NumberValue(20),
        ]);
        let mut gas = Gas::default();
        assert!(interpret_one(&Dup(None), &mut gas, &mut stack).is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_dup2() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(5), NumberValue(20)]);
        let expected_stack = VecDeque::from([
            NumberValue(5),
            NumberValue(10),
            NumberValue(5),
            NumberValue(20),
        ]);
        let mut gas = Gas::default();
        assert!(interpret_one(&Dup(Some(2)), &mut gas, &mut stack).is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_gt() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(20)]);
        let expected_stack = VecDeque::from([BooleanValue(true), NumberValue(20)]);
        let mut gas = Gas::default();
        assert!(interpret_one(&Gt, &mut gas, &mut stack).is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_if_t() {
        let mut stack = VecDeque::from([BooleanValue(true), NumberValue(5), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(20)]);
        let mut gas = Gas::default();
        assert!(interpret_one(
            &If(parse("{DROP}").unwrap(), parse("{ADD}").unwrap()),
            &mut gas,
            &mut stack,
        )
        .is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_if_f() {
        let mut stack = VecDeque::from([BooleanValue(false), NumberValue(5), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(25)]);
        let mut gas = Gas::default();
        assert!(interpret_one(
            &If(parse("{DROP}").unwrap(), parse("{ADD}").unwrap()),
            &mut gas,
            &mut stack,
        )
        .is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_int() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(10), NumberValue(20)]);
        let mut gas = Gas::default();
        assert!(interpret_one(&Int, &mut gas, &mut stack).is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_push() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(0), NumberValue(10), NumberValue(20)]);
        let mut gas = Gas::default();
        assert!(interpret_one(&Push(Type::Nat, NumberValue(0)), &mut gas, &mut stack).is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_loop_0() {
        let mut stack = VecDeque::from([BooleanValue(false), NumberValue(10), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(10), NumberValue(20)]);
        let mut gas = Gas::default();
        assert!(interpret_one(
            &Loop(parse("{PUSH nat 1; ADD; PUSH bool False}").unwrap()),
            &mut gas,
            &mut stack,
        )
        .is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_loop_1() {
        let mut stack = VecDeque::from([BooleanValue(true), NumberValue(10), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(11), NumberValue(20)]);
        let mut gas = Gas::default();
        assert!(interpret_one(
            &Loop(parse("{PUSH nat 1; ADD; PUSH bool False}").unwrap()),
            &mut gas,
            &mut stack,
        )
        .is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_loop_many() {
        let mut stack = VecDeque::from([BooleanValue(true), NumberValue(10), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(0), NumberValue(20)]);
        let mut gas = Gas::default();
        assert!(interpret_one(
            &Loop(parse("{PUSH int -1; ADD; DUP; GT}").unwrap()),
            &mut gas,
            &mut stack,
        )
        .is_ok());
        assert_eq!(stack, expected_stack);
    }

    #[test]
    fn test_swap() {
        let mut stack = VecDeque::from([NumberValue(10), NumberValue(20)]);
        let expected_stack = VecDeque::from([NumberValue(20), NumberValue(10)]);
        let mut gas = Gas::default();
        assert!(interpret_one(&Swap, &mut gas, &mut stack).is_ok());
        assert_eq!(stack, expected_stack);
    }
}