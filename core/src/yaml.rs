//! Safe, order-preserving YAML/JSON loading and the minimal YAML writer used for node files.
//!
//! Built on the `yaml-rust2` event parser so the loader sees each scalar's style and tag:
//! only standard tags are accepted (YAML can never construct arbitrary objects), alias
//! expansion is size-limited, merge keys (`<<`) are supported, and plain `yes/no/on/off`
//! resolve to booleans as PyYAML (and mihomo's own boolean fields) do.

use std::collections::HashMap;
use std::fmt;

use serde_json::{Map, Number, Value};
use yaml_rust2::parser::{Event, Parser, Tag};
use yaml_rust2::scanner::TScalarStyle;

#[derive(Debug, Clone, PartialEq)]
pub struct YamlError(pub String);

impl fmt::Display for YamlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for YamlError {}

const MAX_DEPTH: usize = 200;
const MAX_ALIAS_EXPANSION: usize = 1_000_000;

/// Parses one YAML (or JSON) document into an order-preserving value.
pub fn parse_yaml(text: &str) -> Result<Value, YamlError> {
    let text = text.strip_prefix('\u{FEFF}').unwrap_or(text);
    let mut loader = Loader { parser: Parser::new_from_str(text), anchors: HashMap::new(), expanded: 0, depth: 0 };
    loader.document()
}

struct Loader<'a> {
    parser: Parser<std::str::Chars<'a>>,
    anchors: HashMap<usize, Value>,
    expanded: usize,
    depth: usize,
}

enum Slot {
    Key(String),
    Merge(Vec<Map<String, Value>>),
}

impl Loader<'_> {
    fn next(&mut self) -> Result<Event, YamlError> {
        self.parser
            .next_token()
            .map(|(event, _)| event)
            .map_err(|error| YamlError(error.to_string()))
    }

    fn document(&mut self) -> Result<Value, YamlError> {
        let mut value = Value::Null;
        let mut documents = 0;
        loop {
            match self.next()? {
                Event::StreamStart | Event::DocumentEnd | Event::Nothing => {}
                Event::StreamEnd => return Ok(value),
                Event::DocumentStart => {
                    documents += 1;
                    if documents > 1 {
                        return Err(YamlError("multiple YAML documents are not supported".into()));
                    }
                    let event = self.next()?;
                    value = self.node(event)?;
                }
                other => {
                    // Some parser versions emit the root node without an explicit document start.
                    documents += 1;
                    value = self.node(other)?;
                }
            }
        }
    }

    fn node(&mut self, event: Event) -> Result<Value, YamlError> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(YamlError("nesting too deep".into()));
        }
        let result = self.node_inner(event);
        self.depth -= 1;
        result
    }

    fn node_inner(&mut self, event: Event) -> Result<Value, YamlError> {
        match event {
            Event::Alias(id) => {
                let value = self.anchors.get(&id).cloned().ok_or_else(|| YamlError("unknown or recursive alias".into()))?;
                self.expanded += size_of(&value);
                if self.expanded > MAX_ALIAS_EXPANSION {
                    return Err(YamlError("too many alias expansions".into()));
                }
                Ok(value)
            }
            Event::Scalar(text, style, anchor, tag) => {
                let tag = check_tag(tag.as_ref())?;
                let value = scalar(&text, style, tag.as_deref())?;
                self.remember(anchor, &value);
                Ok(value)
            }
            Event::SequenceStart(anchor, tag) => {
                let tag = check_tag(tag.as_ref())?;
                if !matches!(tag.as_deref(), None | Some("seq")) {
                    return Err(YamlError("tag does not match a sequence".into()));
                }
                let mut items = Vec::new();
                loop {
                    match self.next()? {
                        Event::SequenceEnd => break,
                        event => items.push(self.node(event)?),
                    }
                }
                let value = Value::Array(items);
                self.remember(anchor, &value);
                Ok(value)
            }
            Event::MappingStart(anchor, tag) => {
                let tag = check_tag(tag.as_ref())?;
                if !matches!(tag.as_deref(), None | Some("map")) {
                    return Err(YamlError("tag does not match a mapping".into()));
                }
                let value = Value::Object(self.mapping()?);
                self.remember(anchor, &value);
                Ok(value)
            }
            _ => Err(YamlError("unexpected YAML structure".into())),
        }
    }

    fn mapping(&mut self) -> Result<Map<String, Value>, YamlError> {
        let mut explicit = Map::new();
        let mut order = Vec::new();
        loop {
            let event = self.next()?;
            if event == Event::MappingEnd {
                break;
            }
            let is_merge = matches!(&event, Event::Scalar(text, TScalarStyle::Plain, _, None) if text == "<<");
            let key = self.node(event)?;
            let value_event = self.next()?;
            let value = self.node(value_event)?;
            if is_merge {
                order.push(Slot::Merge(merge_sources(value)?));
                continue;
            }
            let Value::String(key) = key else {
                return Err(YamlError("mapping keys must be strings".into()));
            };
            if !explicit.contains_key(&key) {
                order.push(Slot::Key(key.clone()));
            }
            explicit.insert(key, value);
        }
        // Merged entries go where `<<` appears; explicit keys win, and the first merge source wins.
        let mut result = Map::new();
        for slot in order {
            match slot {
                Slot::Key(key) => {
                    let value = explicit[&key].clone();
                    result.insert(key, value);
                }
                Slot::Merge(sources) => {
                    for source in sources {
                        for (key, value) in source {
                            if !explicit.contains_key(&key) && !result.contains_key(&key) {
                                result.insert(key, value);
                            }
                        }
                    }
                }
            }
        }
        Ok(result)
    }

    fn remember(&mut self, anchor: usize, value: &Value) {
        if anchor > 0 {
            self.anchors.insert(anchor, value.clone());
        }
    }
}

fn merge_sources(value: Value) -> Result<Vec<Map<String, Value>>, YamlError> {
    match value {
        Value::Object(map) => Ok(vec![map]),
        Value::Array(items) => items
            .into_iter()
            .map(|item| match item {
                Value::Object(map) => Ok(map),
                _ => Err(YamlError("merge sources must be mappings".into())),
            })
            .collect(),
        _ => Err(YamlError("merge sources must be mappings".into())),
    }
}

fn size_of(value: &Value) -> usize {
    match value {
        Value::Array(items) => 1 + items.iter().map(size_of).sum::<usize>(),
        Value::Object(map) => 1 + map.values().map(size_of).sum::<usize>(),
        _ => 1,
    }
}

/// Returns the standard tag name ("str", "int", …) or None; rejects every other tag.
fn check_tag(tag: Option<&Tag>) -> Result<Option<String>, YamlError> {
    let Some(tag) = tag else { return Ok(None) };
    if tag.handle == "!" && tag.suffix.is_empty() {
        return Ok(None);
    }
    let standard = tag.handle == "!!" || tag.handle == "tag:yaml.org,2002:";
    let allowed = ["str", "int", "float", "bool", "null", "map", "seq"];
    if standard && allowed.contains(&tag.suffix.as_str()) {
        return Ok(Some(tag.suffix.clone()));
    }
    Err(YamlError(format!("unsupported tag {}{}", tag.handle, tag.suffix)))
}

fn scalar(text: &str, style: TScalarStyle, tag: Option<&str>) -> Result<Value, YamlError> {
    let resolved = if style == TScalarStyle::Plain { resolve_plain(text)? } else { Value::String(text.to_string()) };
    match tag {
        None => Ok(resolved),
        Some("str") => Ok(Value::String(text.to_string())),
        Some("int") => match resolve_plain(text)? {
            value @ Value::Number(_) if value.as_i64().is_some() || value.as_u64().is_some() => Ok(value),
            _ => Err(YamlError("value is not an integer".into())),
        },
        Some("float") => match resolve_plain(text)? {
            Value::Number(number) => Ok(float(number.as_f64().unwrap_or(0.0))?),
            _ => Err(YamlError("value is not a float".into())),
        },
        Some("bool") => match resolve_plain(text)? {
            value @ Value::Bool(_) => Ok(value),
            _ => Err(YamlError("value is not a boolean".into())),
        },
        Some("null") => match resolve_plain(text)? {
            Value::Null => Ok(Value::Null),
            _ => Err(YamlError("value is not null".into())),
        },
        Some(_) => Err(YamlError("tag does not match a scalar".into())),
    }
}

fn float(value: f64) -> Result<Value, YamlError> {
    Number::from_f64(value)
        .map(Value::Number)
        .ok_or_else(|| YamlError("infinite or NaN numbers are not supported".into()))
}

/// YAML 1.2 core schema, plus the YAML 1.1 words yes/no/on/off as booleans.
pub fn resolve_plain(text: &str) -> Result<Value, YamlError> {
    match text {
        "" | "~" | "null" | "Null" | "NULL" => return Ok(Value::Null),
        "true" | "True" | "TRUE" | "yes" | "Yes" | "YES" | "on" | "On" | "ON" => return Ok(Value::Bool(true)),
        "false" | "False" | "FALSE" | "no" | "No" | "NO" | "off" | "Off" | "OFF" => return Ok(Value::Bool(false)),
        ".inf" | ".Inf" | ".INF" | "+.inf" | "+.Inf" | "+.INF" | "-.inf" | "-.Inf" | "-.INF" | ".nan" | ".NaN" | ".NAN" => {
            return Err(YamlError("infinite or NaN numbers are not supported".into()))
        }
        _ => {}
    }
    let digits = text.strip_prefix(['-', '+']).unwrap_or(text);
    if !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit()) {
        let unsigned = text.strip_prefix('+').unwrap_or(text);
        if let Ok(value) = unsigned.parse::<i64>() {
            return Ok(Value::Number(value.into()));
        }
        if let Ok(value) = unsigned.parse::<u64>() {
            return Ok(Value::Number(value.into()));
        }
        return float(unsigned.parse::<f64>().unwrap_or(0.0));
    }
    if let Some(hex) = text.strip_prefix("0x") {
        if let Ok(value) = i64::from_str_radix(hex, 16) {
            return Ok(Value::Number(value.into()));
        }
    }
    if let Some(octal) = text.strip_prefix("0o") {
        if let Ok(value) = i64::from_str_radix(octal, 8) {
            return Ok(Value::Number(value.into()));
        }
    }
    if is_float(text) {
        if let Ok(value) = text.parse::<f64>() {
            return float(value);
        }
    }
    Ok(Value::String(text.to_string()))
}

/// Matches `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`.
fn is_float(text: &str) -> bool {
    let body = text.strip_prefix(['-', '+']).unwrap_or(text);
    let (mantissa, exponent) = match body.find(['e', 'E']) {
        Some(index) => (&body[..index], Some(&body[index + 1..])),
        None => (body, None),
    };
    let mantissa_ok = match mantissa.split_once('.') {
        Some((whole, fraction)) => {
            whole.bytes().all(|b| b.is_ascii_digit())
                && fraction.bytes().all(|b| b.is_ascii_digit())
                && !(whole.is_empty() && fraction.is_empty())
        }
        None => !mantissa.is_empty() && mantissa.bytes().all(|b| b.is_ascii_digit()),
    };
    let exponent_ok = match exponent {
        None => true,
        Some(value) => {
            let digits = value.strip_prefix(['-', '+']).unwrap_or(value);
            !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())
        }
    };
    mantissa_ok && exponent_ok && (mantissa.contains('.') || exponent.is_some())
}

// ---------------------------------------------------------------------------
// Writers

/// JSON string literal; non-ASCII stays readable.
pub fn json_string(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".into())
}

/// Compact JSON text of a value (key order preserved).
pub fn json_text(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "null".into())
}

fn needs_key_quotes(key: &str) -> bool {
    key.is_empty() || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn scalar_text(value: &Value) -> String {
    match value {
        Value::String(text) => json_string(text),
        other => json_text(other),
    }
}

/// Minimal, type-safe YAML writer for node files and configs (strings are always double-quoted).
pub fn to_yaml(map: &Map<String, Value>, indent: usize) -> String {
    let pad = " ".repeat(indent);
    let mut out: Vec<String> = Vec::new();
    for (raw_key, value) in map {
        let key = if needs_key_quotes(raw_key) { json_string(raw_key) } else { raw_key.clone() };
        match value {
            Value::Object(child) => {
                if child.is_empty() {
                    out.push(format!("{pad}{key}: {{}}"));
                } else {
                    out.push(format!("{pad}{key}:"));
                    out.push(to_yaml(child, indent + 2));
                }
            }
            Value::Array(items) => {
                if items.is_empty() {
                    out.push(format!("{pad}{key}: []"));
                    continue;
                }
                let inline = items.iter().all(|item| match item {
                    Value::String(text) => !(text.contains(':') || text.starts_with(['-', '[', '{'])),
                    Value::Number(_) | Value::Bool(_) => true,
                    _ => false,
                });
                if inline {
                    let parts: Vec<String> = items.iter().map(scalar_text).collect();
                    out.push(format!("{pad}{key}: [{}]", parts.join(", ")));
                } else {
                    out.push(format!("{pad}{key}:"));
                    for item in items {
                        match item {
                            Value::Object(child) if !child.is_empty() => {
                                let text = to_yaml(child, indent + 4);
                                let mut lines = text.lines();
                                if let Some(first) = lines.next() {
                                    out.push(format!("{pad}  - {}", first.trim_start()));
                                }
                                out.extend(lines.map(str::to_string));
                            }
                            other => out.push(format!("{pad}  - {}", scalar_text(other))),
                        }
                    }
                }
            }
            other => out.push(format!("{pad}{key}: {}", scalar_text(other))),
        }
    }
    out.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn clash_yaml_with_flow_anchors_merge_and_block_scalars() {
        let text = r#"
base: &base
  udp: true
proxies:
  - {name: "香港 01 | 2x", type: trojan, server: hk.example.com, port: 443, password: "p@ss:word#1"}
  - {"name":"JSON style","port":8388,"password":"x\"y\\zé"}
  - name: 'single ''quoted'''
    <<: *base
    port: 0x1BB
    tls: yes
    folded: >
      one
      two
    literal: |-
      keep
        indent
rules:
  - DOMAIN-SUFFIX,google.com,PROXY   # comment
  - 'IP-CIDR,1.1.1.1/32,DIRECT,no-resolve'
"#;
        let value = parse_yaml(text).unwrap();
        assert_eq!(value["proxies"][0]["name"], "香港 01 | 2x");
        assert_eq!(value["proxies"][0]["password"], "p@ss:word#1");
        assert_eq!(value["proxies"][1]["password"], "x\"y\\zé");
        let third = value["proxies"][2].as_object().unwrap();
        assert_eq!(third.keys().collect::<Vec<_>>(), ["name", "udp", "port", "tls", "folded", "literal"]);
        assert_eq!(third["port"], 443);
        assert_eq!(third["tls"], true);
        assert_eq!(third["folded"], "one two\n");
        assert_eq!(third["literal"], "keep\n  indent");
        assert_eq!(value["rules"][0], "DOMAIN-SUFFIX,google.com,PROXY");
    }

    #[test]
    fn unsafe_or_malformed_input_is_rejected() {
        for text in [
            "!!python/object/apply:builtins.str [unsafe]",
            "!ruby/object:Object {}",
            "proxies: &loop [*loop]",
            "a: [1, 2",
            "a: \"unterminated",
            "a: .inf",
            "--- 1\n--- 2\n",
        ] {
            assert!(parse_yaml(text).is_err(), "should reject {text:?}");
        }
    }

    #[test]
    fn scalars_resolve_like_the_core_schema() {
        assert_eq!(parse_yaml("[1, -2, 1.5, 1e3, null, ~, true, off, '1', 0o17, abc]").unwrap(),
                   json!([1, -2, 1.5, 1000.0, null, null, true, false, "1", 15, "abc"]));
        assert_eq!(parse_yaml("").unwrap(), Value::Null);
    }

    #[test]
    fn writer_round_trips_quotes_lists_and_nesting() {
        let node = json!({"name": "测试 \"节点\"", "type": "trojan", "port": 443, "tls": true, "ratio": 1.5,
                          "alpn": ["quote\"here", "back\\slash", "colon:value"], "list": [1, 2],
                          "ws-opts": {"path": "/a b", "headers": {"Host": "x"}}, "empty": {}, "none": null,
                          "line": "multi\nline"});
        let document = json!({"proxies": [node.clone()]});
        let text = to_yaml(document.as_object().unwrap(), 0);
        assert_eq!(parse_yaml(&text).unwrap()["proxies"][0], node);
    }

    #[test]
    fn alias_bombs_are_limited() {
        let mut text = String::from("a: &a [1,1,1,1,1,1,1,1,1,1]\n");
        let mut previous = 'a';
        for name in ['b', 'c', 'd', 'e', 'f', 'g', 'h'] {
            text += &format!("{name}: &{name} [*{previous},*{previous},*{previous},*{previous},*{previous},*{previous},*{previous},*{previous},*{previous},*{previous}]\n");
            previous = name;
        }
        assert!(parse_yaml(&text).is_err());
    }
}
