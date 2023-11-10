/******************************************************************************/
/*                                                                            */
/* SPDX-License-Identifier: MIT                                               */
/* Copyright (c) [2023] Serokell <hi@serokell.io>                             */
/*                                                                            */
/******************************************************************************/

mod expectation;

use std::fmt;

use crate::ast::michelson_address::AddressHash;
use crate::ast::*;
use crate::context::*;
use crate::interpreter::*;
use crate::irrefutable_match::irrefutable_match;
use crate::parser::spanned_lexer;
use crate::parser::Parser;
use crate::stack::*;
use crate::syntax::tztTestEntitiesParser;
use crate::typechecker::*;
use crate::tzt::expectation::*;

pub type TestStack = Vec<(Type, TypedValue)>;

#[derive(PartialEq, Eq, Clone, Debug)]
pub enum TztTestError<'a> {
    StackMismatch((FailingTypeStack, IStack), (FailingTypeStack, IStack)),
    UnexpectedError(TestError),
    UnexpectedSuccess(ErrorExpectation<'a>, IStack),
    ExpectedDifferentError(ErrorExpectation<'a>, TestError),
}

impl fmt::Display for TztTestError<'_> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        use TztTestError::*;
        match self {
            StackMismatch(e, r) => {
                write!(f, "Stack mismatch: Expected {:?}, Real {:?}", e, r)
            }
            UnexpectedError(e) => {
                write!(f, "Unexpected error during test code execution: {}", e)
            }
            UnexpectedSuccess(e, stk) => {
                write!(
                    f,
                    "Expected an error but none occured. Expected {} but ended with stack {:?}.",
                    e, stk
                )
            }
            ExpectedDifferentError(e, r) => {
                write!(
                    f,
                    "Expected an error but got a different one.\n expected: {}\n got: {}.",
                    e, r
                )
            }
        }
    }
}

/// Represent one Tzt test.
#[derive(Debug, PartialEq, Eq, Clone)]
pub struct TztTest<'a> {
    pub code: Micheline<'a>,
    pub input: TestStack,
    pub output: TestExpectation<'a>,
    pub amount: Option<i64>,
    pub chain_id: Option<ChainId>,
    pub parameter: Option<Type>,
    pub self_addr: Option<AddressHash>,
}

fn typecheck_stack(stk: Vec<(Micheline, Micheline)>) -> Result<Vec<(Type, TypedValue)>, TcError> {
    stk.into_iter()
        .map(|(t, v)| {
            let t = t.typecheck_ty(&mut Ctx::default())?;
            let tc_val = v.typecheck_value(&mut Default::default(), &t)?;
            Ok((t, tc_val))
        })
        .collect()
}

impl<'a> Parser<'a> {
    pub fn parse_tzt_test(&'a self, src: &str) -> Result<TztTest, Box<dyn Error + '_>> {
        tztTestEntitiesParser::new()
            .parse(&self.arena, spanned_lexer(src))?
            .try_into()
    }
}

// Check if the option argument value is none, and raise an error if it is not.
// If it is none, then fill it with the provided value.
fn set_tzt_field<T>(field_name: &str, t: &mut Option<T>, v: T) -> Result<(), String> {
    match t {
        Some(_) => Err(format!("Duplicate field '{}' in test", field_name)),
        None => {
            *t = Some(v);
            Ok(())
        }
    }
}

use std::error::Error;
impl<'a> TryFrom<Vec<TztEntity<'a>>> for TztTest<'a> {
    type Error = Box<dyn Error>;
    fn try_from(tzt: Vec<TztEntity<'a>>) -> Result<Self, Self::Error> {
        use TestExpectation::*;
        use TztEntity::*;
        use TztOutput::*;
        let mut m_code: Option<Micheline> = None;
        let mut m_input: Option<TestStack> = None;
        let mut m_output: Option<TestExpectation> = None;
        let mut m_amount: Option<i64> = None;
        let mut m_chain_id: Option<Micheline> = None;
        let mut m_parameter: Option<Micheline> = None;
        let mut m_self: Option<Micheline> = None;

        for e in tzt {
            match e {
                Code(ib) => set_tzt_field("code", &mut m_code, ib)?,
                Input(stk) => set_tzt_field("input", &mut m_input, typecheck_stack(stk)?)?,
                Output(tzt_output) => set_tzt_field(
                    "output",
                    &mut m_output,
                    match tzt_output {
                        TztSuccess(stk) => ExpectSuccess(typecheck_stack(stk)?),
                        TztError(error_exp) => ExpectError(error_exp),
                    },
                )?,
                Amount(m) => set_tzt_field("amount", &mut m_amount, m)?,
                ChainId(id) => set_tzt_field("chain_id", &mut m_chain_id, id)?,
                Parameter(ty) => set_tzt_field("parameter", &mut m_parameter, ty)?,
                SelfAddr(v) => set_tzt_field("self", &mut m_self, v)?,
            }
        }

        Ok(TztTest {
            code: m_code.ok_or("code section not found in test")?,
            input: m_input.ok_or("input section not found in test")?,
            output: m_output.ok_or("output section not found in test")?,
            amount: m_amount,
            chain_id: m_chain_id
                .map(|v| {
                    Ok::<_, TcError>(irrefutable_match!(
                        v.typecheck_value(&mut Ctx::default(), &Type::ChainId)?;
                        TypedValue::ChainId
                    ))
                })
                .transpose()?,
            parameter: m_parameter
                .map(|v| v.typecheck_ty(&mut Ctx::default()))
                .transpose()?,
            self_addr: m_self
                .map(|v| {
                    Ok::<_, TcError>(
                        irrefutable_match!(
                            v.typecheck_value(&mut Ctx::default(), &Type::Address)?;
                            TypedValue::Address
                        )
                        .hash,
                    )
                })
                .transpose()?,
        })
    }
}

/// This represents possibilities in which the execution of
/// the code in a test can fail.
#[derive(Debug, PartialEq, Eq, Clone, thiserror::Error)]
pub enum TestError {
    #[error(transparent)]
    TypecheckerError(#[from] TcError),
    #[error(transparent)]
    InterpreterError(#[from] InterpretError),
}

/// This represents the outcome that we expect from interpreting
/// the code in a test.
#[derive(Debug, PartialEq, Eq, Clone)]
pub enum TestExpectation<'a> {
    ExpectSuccess(Vec<(Type, TypedValue)>),
    ExpectError(ErrorExpectation<'a>),
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum ErrorExpectation<'a> {
    TypecheckerError(Option<String>),
    InterpreterError(InterpreterErrorExpectation<'a>),
}

impl fmt::Display for ErrorExpectation<'_> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        use ErrorExpectation::*;
        match self {
            TypecheckerError(None) => write!(f, "some typechecker error"),
            TypecheckerError(Some(err)) => write!(f, "typechecker error: {}", err),
            InterpreterError(err) => write!(f, "interpreter error: {}", err),
        }
    }
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum InterpreterErrorExpectation<'a> {
    GeneralOverflow(i128, i128),
    MutezOverflow(i64, i64),
    FailedWith(Micheline<'a>),
}

impl fmt::Display for InterpreterErrorExpectation<'_> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        use InterpreterErrorExpectation::*;
        match self {
            GeneralOverflow(a1, a2) => write!(f, "General Overflow {} {}", a1, a2),
            MutezOverflow(a1, a2) => write!(f, "MutezOverflow {} {}", a1, a2),
            FailedWith(v) => write!(f, "FailedWith {:?}", v),
        }
    }
}

/// Helper type for use during parsing, represent a single
/// line from the test file.
pub enum TztEntity<'a> {
    Code(Micheline<'a>),
    Input(Vec<(Micheline<'a>, Micheline<'a>)>),
    Output(TztOutput<'a>),
    Amount(i64),
    ChainId(Micheline<'a>),
    Parameter(Micheline<'a>),
    SelfAddr(Micheline<'a>),
}

/// Possible values for the "output" expectation field in a Tzt test
pub enum TztOutput<'a> {
    TztSuccess(Vec<(Micheline<'a>, Micheline<'a>)>),
    TztError(ErrorExpectation<'a>),
}

fn execute_tzt_test_code(
    code: Micheline,
    ctx: &mut Ctx,
    parameter: &Type,
    input: Vec<(Type, TypedValue)>,
) -> Result<(FailingTypeStack, IStack), TestError> {
    // Build initial stacks (type and value) for running the test from the test input
    // stack.
    let (typs, vals): (Vec<Type>, Vec<TypedValue>) = input.into_iter().unzip();

    let mut t_stack: FailingTypeStack = FailingTypeStack::Ok(TopIsFirst::from(typs).0);

    // Run the code and save the status of the
    // final result as a Result<(), TestError>.
    //
    // This value along with the test expectation
    // from the test file will be used to decide if
    // the test was a success or a fail.
    let typechecked_code = code.typecheck(ctx, Some(parameter), &mut t_stack)?;
    let mut i_stack: IStack = TopIsFirst::from(vals).0;
    typechecked_code.interpret(ctx, &mut i_stack)?;
    Ok((t_stack, i_stack))
}

pub fn run_tzt_test(test: TztTest) -> Result<(), TztTestError> {
    // Here we compare the outcome of the interpreting with the
    // expectation from the test, and declare the result of the test
    // accordingly.
    let mut ctx = Ctx {
        gas: crate::gas::Gas::default(),
        amount: test.amount.unwrap_or_default(),
        chain_id: test.chain_id.unwrap_or(Ctx::default().chain_id),
        self_address: test.self_addr.unwrap_or(Ctx::default().self_address),
    };
    let execution_result = execute_tzt_test_code(
        test.code,
        &mut ctx,
        &test.parameter.unwrap_or(Type::Unit),
        test.input,
    );
    check_expectation(&mut ctx, test.output, execution_result)
}
