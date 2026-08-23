use std::collections::BTreeMap;
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::{Args, Parser, Subcommand};
use counterweave::adapter::AdapterRunner;
use counterweave::artifact::{
    CaseArtifact, GenerationProvenance, Intent, ModelProvenance, PackIdentity,
};
use counterweave::choice::{ChoiceSession, ForkPath};
use counterweave::minizinc::MiniZinc;
use serde_json::{Map, Number, Value};

#[derive(Debug, Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Generate one materialized case through `MiniZinc`.
    Generate(Generate),
    /// Execute a materialized case through an isolated adapter process.
    Execute(Execute),
    /// Print a concise case summary.
    Inspect(Inspect),
}

#[derive(Debug, Args)]
struct Generate {
    /// `MiniZinc` model entry point.
    #[arg(long)]
    model: PathBuf,
    /// Optional JSON model data.
    #[arg(long)]
    data: Option<PathBuf>,
    /// `MiniZinc` solver identifier.
    #[arg(long, default_value = "cp-sat")]
    solver: String,
    /// Root choice seed. A random seed is selected when omitted.
    #[arg(long)]
    seed: Option<u64>,
    /// Draw and inject a JSON integer parameter: NAME=MIN..MAX.
    #[arg(long = "draw", value_parser = parse_draw)]
    draws: Vec<DrawSpec>,
    /// Model-pack name.
    #[arg(long)]
    pack: String,
    /// Model-pack compatibility version.
    #[arg(long, default_value = "1")]
    pack_version: String,
    /// Intent family.
    #[arg(long, default_value = "satisfy")]
    intent: String,
    /// Pack-defined target.
    #[arg(long, default_value = "default")]
    target: String,
    /// Destination `.cwcase` file.
    #[arg(long)]
    output: PathBuf,
}

#[derive(Clone, Debug)]
struct DrawSpec {
    name: String,
    minimum: i64,
    maximum: i64,
}

#[derive(Debug, Args)]
struct Execute {
    /// Materialized `.cwcase` file.
    #[arg(long)]
    case: PathBuf,
    /// Adapter executable.
    #[arg(long)]
    adapter: PathBuf,
    /// Adapter deadline in milliseconds.
    #[arg(long, default_value_t = 5_000)]
    timeout_ms: u64,
    /// Destination `.cwrun` file.
    #[arg(long)]
    output: PathBuf,
    /// Fixed arguments passed after the adapter executable.
    #[arg(last = true)]
    adapter_arguments: Vec<String>,
}

#[derive(Debug, Args)]
struct Inspect {
    /// Materialized `.cwcase` file.
    case: PathBuf,
    /// Include the opaque pack payload.
    #[arg(long)]
    payload: bool,
}

fn main() {
    if let Err(error) = run(Cli::parse()) {
        eprintln!("counterweave: {error}");
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<(), Box<dyn Error>> {
    match cli.command {
        Command::Generate(arguments) => generate(&arguments),
        Command::Execute(arguments) => execute(&arguments),
        Command::Inspect(arguments) => inspect(&arguments),
    }
}

fn generate(arguments: &Generate) -> Result<(), Box<dyn Error>> {
    let root_seed = arguments.seed.unwrap_or_else(rand::random);
    let mut choices = ChoiceSession::recording(root_seed);
    let mut data = read_data(arguments.data.as_deref())?;
    let drawn = draw_parameters(&mut choices, &arguments.draws, &mut data)?;

    let solver_seed = choices
        .fork(&ForkPath::root().child("completion", 0))?
        .draw()?;
    let tape = choices.finish()?;

    let temporary_data = TemporaryData::write(&data)?;
    let minizinc = MiniZinc::new(&arguments.solver);
    let version = minizinc.version()?;
    let solution =
        minizinc.solve_one(&arguments.model, Some(temporary_data.path()), solver_seed)?;

    let model_bytes = fs::read(&arguments.model)?;
    let payload = serde_json::json!({
        "parameters": data,
        "drawn": drawn,
        "solution": solution.value,
    });
    let case = CaseArtifact::new(
        PackIdentity {
            name: arguments.pack.clone(),
            version: arguments.pack_version.clone(),
        },
        Intent {
            kind: arguments.intent.clone(),
            target: arguments.target.clone(),
        },
        GenerationProvenance {
            choices: tape,
            model: ModelProvenance {
                backend: "minizinc".to_owned(),
                solver: arguments.solver.clone(),
                minizinc_version: version,
                model_hash: blake3::hash(&model_bytes).to_hex().to_string(),
                solver_seed: solution.random_seed_applied.then_some(solver_seed),
            },
        },
        payload,
    );
    case.write(&arguments.output)?;
    println!("generated {}", arguments.output.display());
    println!("seed: {root_seed}");
    if !solution.diagnostics.trim().is_empty() {
        eprintln!("{}", solution.diagnostics.trim());
    }
    Ok(())
}

fn execute(arguments: &Execute) -> Result<(), Box<dyn Error>> {
    let case = CaseArtifact::read(&arguments.case)?;
    let runner = AdapterRunner::new(&arguments.adapter)
        .arguments(arguments.adapter_arguments.clone())
        .timeout(Duration::from_millis(arguments.timeout_ms));
    let run = runner.execute(&case)?;
    run.write(&arguments.output)?;
    println!("wrote {} ({:?})", arguments.output.display(), run.outcome);
    Ok(())
}

fn inspect(arguments: &Inspect) -> Result<(), Box<dyn Error>> {
    let case = CaseArtifact::read(&arguments.case)?;
    println!("pack: {}@{}", case.pack.name, case.pack.version);
    println!("intent: {}:{}", case.intent.kind, case.intent.target);
    println!("seed: {}", case.provenance.choices.root_seed);
    println!(
        "model: {} via {}",
        case.provenance.model.model_hash, case.provenance.model.solver
    );
    println!("case: {}", case.digest()?);
    if arguments.payload {
        println!("{}", serde_json::to_string_pretty(&case.payload)?);
    }
    Ok(())
}

fn read_data(path: Option<&Path>) -> Result<Value, Box<dyn Error>> {
    let Some(path) = path else {
        return Ok(Value::Object(Map::new()));
    };
    if path
        .extension()
        .is_some_and(|extension| extension == "json")
    {
        let value: Value = serde_json::from_slice(&fs::read(path)?)?;
        if !value.is_object() {
            return Err("MiniZinc JSON data must be an object".into());
        }
        Ok(value)
    } else {
        Err("Counterweave generation currently accepts JSON data only".into())
    }
}

fn draw_parameters(
    choices: &mut ChoiceSession,
    draws: &[DrawSpec],
    data: &mut Value,
) -> Result<BTreeMap<String, i64>, Box<dyn Error>> {
    let object = data
        .as_object_mut()
        .ok_or("MiniZinc JSON data must be an object")?;
    let mut selected = BTreeMap::new();
    for draw in draws {
        let width = i128::from(draw.maximum) - i128::from(draw.minimum);
        let maximum_offset = u64::try_from(width).map_err(|_| "draw range is too wide")?;
        let path = ForkPath::root().child("parameter", 0).child(&draw.name, 0);
        let offset = choices.fork(&path)?.draw_bounded(maximum_offset)?;
        let value = i128::from(draw.minimum) + i128::from(offset);
        let value = i64::try_from(value).map_err(|_| "draw result is outside i64")?;
        object.insert(draw.name.clone(), Value::Number(Number::from(value)));
        selected.insert(draw.name.clone(), value);
    }
    Ok(selected)
}

fn parse_draw(text: &str) -> Result<DrawSpec, String> {
    let (name, range) = text
        .split_once('=')
        .ok_or_else(|| "expected NAME=MIN..MAX".to_owned())?;
    let (minimum, maximum) = range
        .split_once("..")
        .ok_or_else(|| "expected NAME=MIN..MAX".to_owned())?;
    if name.is_empty() {
        return Err("draw name must not be empty".to_owned());
    }
    let minimum = minimum
        .parse::<i64>()
        .map_err(|error| format!("invalid minimum: {error}"))?;
    let maximum = maximum
        .parse::<i64>()
        .map_err(|error| format!("invalid maximum: {error}"))?;
    if minimum > maximum {
        return Err("draw minimum must not exceed maximum".to_owned());
    }
    Ok(DrawSpec {
        name: name.to_owned(),
        minimum,
        maximum,
    })
}

struct TemporaryData {
    path: PathBuf,
}

impl TemporaryData {
    fn write(value: &Value) -> Result<Self, Box<dyn Error>> {
        let path = std::env::temp_dir().join(format!(
            "counterweave-data-{}-{}.json",
            std::process::id(),
            rand::random::<u64>()
        ));
        fs::write(&path, serde_json::to_vec(value)?)?;
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TemporaryData {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_signed_draw_range() {
        let draw = parse_draw("pressure=-2..12").unwrap();
        assert_eq!(draw.name, "pressure");
        assert_eq!(draw.minimum, -2);
        assert_eq!(draw.maximum, 12);
    }

    #[test]
    fn rejects_reversed_draw_range() {
        assert!(parse_draw("count=8..1").is_err());
    }
}
