//! "Render" files using tera templates.

use std::io::{BufRead, Write};
use std::path::Path;
use std::{fs::File, iter};

use crate::{BuildInfo, GenerateInfo};
use anyhow::format_err;
use anyhow::{bail, Error};
use cargo_platform::{Cfg, CfgExpr};
use itertools::Itertools;
use lazy_static::lazy_static;
use serde::Serialize;
use std::collections::HashMap;
use std::{fmt::Debug, marker::PhantomData, str::FromStr};
use tera::{Context, Tera};

macro_rules! template {
    ($x:expr) => {
        Template {
            template: $x,
            #[cfg(not(debug_assertions))]
            content: include_str!(concat!("../templates/", $x)),
            context: PhantomData,
        }
    };
}

/// The template for generating Cargo.nix.
pub const CARGO_NIX: Template<BuildInfo> = template!("Cargo.nix.tera");

/// Included in build.nix.tera
const DEFAULT_NIX: Template<()> = template!("nix/crate2nix/default.nix");

/// The template for generating a directory with all out of tree sources.
pub const SOURCES_NIX: Template<GenerateInfo> = template!("crate2nix-sources.nix.tera");

/// Context argument for the `CARGO_TOML_FOR_WORKSPACE` template.
///
/// This is used to render a `Cargo.toml` for a workspace which
/// is build via nix.
#[derive(Debug, Serialize)]
pub struct CargoTomlForWorkspace {
    /// The generate info for this invocation.
    pub info: GenerateInfo,
    /// The symlink to the workspace member dir derivation output.
    pub workspace_member_dir: String,
    /// The names of the members of this workspace - which are
    /// equal to the names of the subdirectory symlinks.
    pub members: Vec<String>,
}

/// A predefined template.
#[derive(Debug)]
pub struct Template<C: Serialize + Debug> {
    /// Relative path in the templates directory and template name.
    template: &'static str,
    /// The whole content of the template file in release builds.
    #[cfg(not(debug_assertions))]
    content: &'static str,
    context: PhantomData<C>,
}

impl<C: Serialize + Debug> Template<C> {
    /// Returns the rendered template as a string.
    pub fn render(&self, context: &C) -> Result<String, Error> {
        let rendered = TERA
            .render(self.template, &Context::from_serialize(context)?)
            .map_err(|e| {
                format_err!(
                    "while rendering {}: {:#?}\nContext: {:#?}",
                    self.template,
                    e,
                    context
                )
            })?;
        Ok(rendered
            .lines()
            .map(|l| l.trim_end())
            .chain(iter::once("\n"))
            .join("\n"))
    }

    /// Writes the rendered template to the given file path.
    pub fn write_to_file(&self, path: impl AsRef<Path>, context: &C) -> Result<(), Error> {
        let mut output_file = File::create(&path)?;
        output_file.write_all(self.render(context)?.as_bytes())?;
        println!(
            "Generated {} successfully.",
            path.as_ref().to_string_lossy()
        );
        Ok(())
    }
}

/// Ensures that the given path either does not exist or contains a file that
/// was generated by crate2nix.
pub fn check_generated_by_crate2nix(path: impl AsRef<Path>) -> Result<(), Error> {
    if !path.as_ref().exists() {
        return Ok(());
    }

    let reader = std::io::BufReader::new(File::open(path.as_ref())?);
    let generated = reader.lines().any(|l| {
        l.map(|l| l.contains("@generated by crate2nix"))
            .unwrap_or(false)
    });
    if !generated {
        bail!(
            "Cowardly refusing to overwrite {} without generated marker.",
            path.as_ref().to_string_lossy()
        );
    }
    Ok(())
}

trait AbstractTemplate {
    fn template(&self) -> &'static str;
    #[cfg(not(debug_assertions))]
    fn template_content(&self) -> &'static str;
}

impl<C: Serialize + Debug> AbstractTemplate for Template<C> {
    fn template(&self) -> &'static str {
        self.template
    }

    #[cfg(not(debug_assertions))]
    fn template_content(&self) -> &'static str {
        self.content
    }
}

const TEMPLATES: &[&'static dyn AbstractTemplate] = &[&CARGO_NIX, &DEFAULT_NIX, &SOURCES_NIX];

fn create_tera() -> Tera {
    let mut tera = Tera::default();

    // For debug builds, we load the templates from the files during runtime.
    #[cfg(debug_assertions)]
    let template_dir = std::env::var("TEMPLATES_DIR")
        .expect("TEMPLATES_DIR environment variable when running in debug mode");
    #[cfg(debug_assertions)]
    for template in TEMPLATES.iter() {
        let path = Path::new(&template_dir).join(template.template());
        tera.add_template_file(path, Some(template.template()))
            .expect("adding template to succeed");
    }

    // For release builds, we compile the template definitions into the binary.
    #[cfg(not(debug_assertions))]
    tera.add_raw_templates(
        TEMPLATES
            .iter()
            .map(|template| (template.template(), template.template_content()))
            .collect::<Vec<_>>(),
    )
    .expect("adding templats to succeed");

    tera.autoescape_on(vec![".nix.tera", ".nix"]);
    tera.set_escape_fn(escape_nix_string);
    tera.register_filter("cfg_to_nix_expr", cfg_to_nix_expr_filter);
    tera
}

lazy_static! {
    static ref TERA: Tera = create_tera();
}

fn cfg_to_nix_expr_filter(
    value: &tera::Value,
    _args: &HashMap<String, tera::Value>,
) -> tera::Result<tera::Value> {
    match value {
        tera::Value::String(key) => {
            if key.starts_with("cfg(") && key.ends_with(')') {
                let cfg = &key[4..key.len() - 1];

                let expr = CfgExpr::from_str(cfg).map_err(|e| {
                    tera::Error::msg(format!(
                        "cfg_to_nix_expr_filter: Could not parse '{}': {}",
                        cfg, e
                    ))
                })?;
                Ok(tera::Value::String(cfg_to_nix_expr(&expr)))
            } else {
                let condition = format!("(target.name == {})", escape_nix_string(key));
                Ok(tera::Value::String(condition))
            }
        }
        _ => Err(tera::Error::msg(format!(
            "cfg_to_nix_expr_filter: Expected string, got {:?}",
            value
        ))),
    }
}

/// Renders a config expression to nix code.
fn cfg_to_nix_expr(cfg: &CfgExpr) -> String {
    fn target(target_name: &str) -> String {
        escape_nix_string(target_name.strip_prefix("target_").unwrap_or(target_name))
    }

    fn render(result: &mut String, cfg: &CfgExpr) {
        match cfg {
            CfgExpr::Value(Cfg::Name(name)) => {
                result.push_str(&format!("(target.{} or false)", target(name)));
            }
            CfgExpr::Value(Cfg::KeyPair(key, value)) => {
                let escaped_value = escape_nix_string(value);
                result.push_str(&if key == "feature" {
                    format!("(builtins.elem {} features)", escaped_value)
                } else if key == "target_feature" {
                    format!("(builtins.elem {} targetFeatures)", escaped_value)
                } else if key == "target_family" {
                    format!("(builtins.elem {} target.{})", escaped_value, target(key))
                } else {
                    format!("({} == target.{} or null)", escaped_value, target(key))
                });
            }
            CfgExpr::Not(expr) => {
                result.push_str("(!");
                render(result, expr);
                result.push(')');
            }
            CfgExpr::All(expressions) => {
                if expressions.is_empty() {
                    result.push_str("true");
                } else {
                    result.push('(');
                    render(result, &expressions[0]);
                    for expr in &expressions[1..] {
                        result.push_str(" && ");
                        render(result, expr);
                    }
                    result.push(')');
                }
            }
            CfgExpr::Any(expressions) => {
                if expressions.is_empty() {
                    result.push_str("false");
                } else {
                    result.push('(');
                    render(result, &expressions[0]);
                    for expr in &expressions[1..] {
                        result.push_str(" || ");
                        render(result, expr);
                    }
                    result.push(')');
                }
            }
        }
    }

    let mut ret = String::new();
    render(&mut ret, cfg);
    ret
}

#[test]
fn test_render_cfg_to_nix_expr() {
    fn name(value: &str) -> CfgExpr {
        CfgExpr::Value(Cfg::Name(value.to_string()))
    }

    fn kv(key: &str, value: &str) -> CfgExpr {
        CfgExpr::Value(Cfg::KeyPair(key.to_string(), value.to_string()))
    }

    assert_eq!(
        "(target.\"unix\" or false)",
        &cfg_to_nix_expr(&name("unix"))
    );
    assert_eq!(
        "((builtins.elem \"aes\" targetFeatures) && (builtins.elem \"foo\" features))",
        &cfg_to_nix_expr(&CfgExpr::All(vec![
            kv("target_feature", "aes"),
            kv("feature", "foo")
        ]))
    );
    assert_eq!(
        "(builtins.elem \"unix\" target.\"family\")",
        &cfg_to_nix_expr(&kv("target_family", "unix"))
    );
    assert_eq!(
        "(\"linux\" == target.\"os\" or null)",
        &cfg_to_nix_expr(&kv("target_os", "linux"))
    );
    assert_eq!(
        "(!(\"linux\" == target.\"os\" or null))",
        &cfg_to_nix_expr(&CfgExpr::Not(Box::new(kv("target_os", "linux"))))
    );
    assert_eq!(
        "((target.\"unix\" or false) || (\"linux\" == target.\"os\" or null))",
        &cfg_to_nix_expr(&CfgExpr::Any(vec![name("unix"), kv("target_os", "linux")]))
    );
    assert_eq!(
        "((target.\"unix\" or false) && (\"linux\" == target.\"os\" or null))",
        &cfg_to_nix_expr(&CfgExpr::All(vec![name("unix"), kv("target_os", "linux")]))
    );
    assert_eq!("true", &cfg_to_nix_expr(&CfgExpr::All(vec![])));
    assert_eq!("false", &cfg_to_nix_expr(&CfgExpr::Any(vec![])));
}

/// Escapes a string as a nix string.
///
/// ```
/// use crate2nix::render::escape_nix_string;
/// assert_eq!("\"abc\"", escape_nix_string("abc"));
/// assert_eq!("\"a\\\"bc\"", escape_nix_string("a\"bc"));
/// assert_eq!("\"a$bc\"", escape_nix_string("a$bc"));
/// assert_eq!("\"a$\"", escape_nix_string("a$"));
/// assert_eq!("\"a\\${bc\"", escape_nix_string("a${bc"));
/// ```
pub fn escape_nix_string(raw_string: &str) -> String {
    let mut ret = String::with_capacity(raw_string.len() + 2);
    ret.push('"');
    let mut peekable_chars = raw_string.chars().peekable();
    while let Some(c) = peekable_chars.next() {
        if c == '\\' || c == '"' || (c == '$' && peekable_chars.peek() == Some(&'{')) {
            ret.push('\\');
        }
        ret.push(c);
    }
    ret.push('"');
    ret
}
