/// This module provides a utility class to store different type values inside a single field.
/// This can for example be used to model inheritance.
module mongoschema.variant;

import std.meta;
import std.traits;
import std.variant;

import vibe.data.bson;

import mongoschema;

private enum bool distinctFieldNames(names...) = __traits(compiles, {
		static foreach (__name; names)
			static if (is(typeof(__name) : string))
				mixin("enum int " ~ __name ~ " = 0;");
			else
				mixin("enum int " ~ __name.stringof ~ " = 0;");
	});

/// Represents a data type which can hold different kinds of values but always exactly one or none at a time.
/// Types is a list of types the variant can hold. By default type IDs are assigned from the stringof value which is the type name without module name.
/// You can pass custom type names by passing a string following the type.
/// Those will affect the type value in the serialized bson and the convenience access function names.
/// Serializes the Bson as `{"type": "T", "value": "my value here"}`
final struct SchemaVariant(Specs...) if (distinctFieldNames!(Specs))
{
	// Parse (type,name) pairs (FieldSpecs) out of the specified
	// arguments. Some fields would have name, others not.
	private template parseSpecs(Specs...)
	{
		static if (Specs.length == 0)
		{
			alias parseSpecs = AliasSeq!();
		}
		else static if (is(Specs[0]))
		{
			static if (is(typeof(Specs[1]) : string))
			{
				alias parseSpecs = AliasSeq!(FieldSpec!(Specs[0 .. 2]), parseSpecs!(Specs[2 .. $]));
			}
			else
			{
				alias parseSpecs = AliasSeq!(FieldSpec!(Specs[0]), parseSpecs!(Specs[1 .. $]));
			}
		}
		else
		{
			static assert(0,
					"Attempted to instantiate Variant with an invalid argument: " ~ Specs[0].stringof);
		}
	}

	private template specTypes(Specs...)
	{
		static if (Specs.length == 0)
		{
			alias specTypes = AliasSeq!();
		}
		else static if (is(Specs[0]))
		{
			static if (is(typeof(Specs[1]) : string))
			{
				alias specTypes = AliasSeq!(Specs[0], specTypes!(Specs[2 .. $]));
			}
			else
			{
				alias specTypes = AliasSeq!(Specs[0], specTypes!(Specs[1 .. $]));
			}
		}
		else
		{
			static assert(0,
					"Attempted to instantiate Variant with an invalid argument: " ~ Specs[0].stringof);
		}
	}

	private template FieldSpec(T, string s = T.stringof)
	{
		alias Type = T;
		alias name = s;
	}

	alias Fields = parseSpecs!Specs;
	alias Types = specTypes!Specs;

	template typeIndex(T)
	{
		enum hasType = staticIndexOf!(T, Types);
	}

	template hasType(T)
	{
		enum hasType = staticIndexOf!(T, Types) != -1;
	}

public:
	Algebraic!Types value;

	this(T)(T value) @trusted
	{
		this.value = value;
	}

	static foreach (Field; Fields)
		mixin("inout(Field.Type) " ~ Field.name
				~ "() @trusted inout { checkType!(Field.Type); return value.get!(Field.Type); }");

	void checkType(T)() const
	{
		if (!isType!T)
			throw new Exception("Attempted to access " ~ type ~ " field as " ~ T.stringof);
	}

	bool isType(T)() @trusted const
	{
		return value.type == typeid(T);
	}

	string type() const
	{
		if (!value.hasValue)
			return null;

		static foreach (Field; Fields)
			if (isType!(Field.Type))
				return Field.name;

		assert(false, "Checked all possible types of variant but none of them matched?!");
	}

	void opAssign(T)(T value) @trusted if (hasType!T)
	{
		this.value = value;
	}

	static Bson toBson(SchemaVariant!Specs value)
	{
		if (!value.value.hasValue)
			return Bson.init;

		static foreach (Field; Fields)
			if (value.isType!(Field.Type))
				return Bson([
						"type": Bson(Field.name),
						"value": toSchemaBson((() @trusted => value.value.get!(Field.Type))())
						]);

		assert(false, "Checked all possible types of variant but none of them matched?!");
	}

	static SchemaVariant!Specs fromBson(Bson bson)
	{
		if (bson.type != Bson.Type.object)
			return SchemaVariant!Specs.init;
		auto type = "type" in bson.get!(Bson[string]);
		if (!type || type.type != Bson.Type.string)
			throw new Exception(
					"Malformed " ~ SchemaVariant!Specs.stringof ~ " bson, missing or invalid type argument");

		switch (type.get!string)
		{
			static foreach (i, Field; Fields)
			{
		case Field.name:
				return SchemaVariant!Specs(fromSchemaBson!(Field.Type)(bson["value"]));
			}
		default:
			throw new Exception("Invalid " ~ SchemaVariant!Specs.stringof ~ " type " ~ type.get!string);
		}
	}
}

unittest
{
	struct Foo
	{
		int x = 3;
	}

	struct Bar
	{
		string y = "bar";
	}

	SchemaVariant!(Foo, Bar) var1;
	assert(typeof(var1).toBson(var1) == Bson.init);
	var1 = Foo();
	assert(typeof(var1).toBson(var1) == Bson([
				"type": Bson("Foo"),
				"value": Bson(["x": Bson(3)])
			]));
	assert(var1.type == "Foo");
	var1 = Bar();
	assert(typeof(var1).toBson(var1) == Bson([
				"type": Bson("Bar"),
				"value": Bson(["y": Bson("bar")])
			]));
	assert(var1.type == "Bar");

	var1 = typeof(var1).fromBson(Bson([
				"type": Bson("Foo"),
				"value": Bson(["x": Bson(4)])
			]));
	assert(var1.type == "Foo");
	assert(var1.Foo == Foo(4));

	var1 = typeof(var1).fromBson(Bson([
				"type": Bson("Bar"),
				"value": Bson(["y": Bson("barf")])
			]));
	assert(var1.type == "Bar");
	assert(var1.Bar == Bar("barf"));

	SchemaVariant!(Foo, "foo", Bar, "bar") var2;
	assert(typeof(var2).toBson(var2) == Bson.init);
	var2 = Foo();
	assert(var2.type == "foo");
	assert(var2.foo == Foo());
	assert(typeof(var2).toBson(var2) == Bson([
				"type": Bson("foo"),
				"value": Bson(["x": Bson(3)])
			]));

	const x = var2;
	assert(x.type == "foo");
	assert(x.isType!Foo);
	assert(typeof(x).toBson(x) == Bson([
				"type": Bson("foo"),
				"value": Bson(["x": Bson(3)])
			]));
}
