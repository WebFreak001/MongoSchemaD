/// This module provides a typesafe querying framework.
/// For now only very basic queries are supported
module mongoschema.query;

import mongoschema;

import std.regex;
import std.traits;

/// Represents a field to compare
struct FieldQuery(T, Obj)
{
	enum isCompatible(V) = is(V : T) || is(V == Bson);

	Query!Obj* query;
	string name;

	@disable this();
	@disable this(this);

	private this(string name, ref Query!Obj query) @trusted
	{
		this.name = name;
		this.query = &query;
	}

	ref Query!Obj equals(V)(V other) if (isCompatible!V)
	{
		query._query[name] = memberToBson(other);
		return *query;
	}

	alias equal = equals;
	alias eq = equals;

	ref Query!Obj ne(V)(V other) if (isCompatible!V)
	{
		query._query[name] = Bson(["$ne": memberToBson(other)]);
		return *query;
	}

	alias notEqual = ne;
	alias notEquals = ne;

	ref Query!Obj gt(V)(V other) if (isCompatible!V)
	{
		query._query[name] = Bson(["$gt": memberToBson(other)]);
		return *query;
	}

	alias greaterThan = gt;

	ref Query!Obj gte(V)(V other) if (isCompatible!V)
	{
		query._query[name] = Bson(["$gte": memberToBson(other)]);
		return *query;
	}

	alias greaterThanOrEqual = gt;

	ref Query!Obj lt(V)(V other) if (isCompatible!V)
	{
		query._query[name] = Bson(["$lt": memberToBson(other)]);
		return *query;
	}

	alias lessThan = lt;

	ref Query!Obj lte(V)(V other) if (isCompatible!V)
	{
		query._query[name] = Bson(["$lte": memberToBson(other)]);
		return *query;
	}

	alias lessThanOrEqual = lt;

	ref Query!Obj oneOf(Args...)(Args other)
	{
		Bson[] arr = new Bson(Args.length);
		static foreach (i, arg; other)
			arr[i] = memberToBson(arg);
		query._query[name] = Bson(["$in": Bson(arr)]);
		return *query;
	}

	ref Query!Obj inArray(V)(V[] array) if (isCompatible!V)
	{
		query._query[name] = Bson(["$in": memberToBson(array)]);
		return *query;
	}

	ref Query!Obj noneOf(Args...)(Args other)
	{
		Bson[] arr = new Bson(Args.length);
		static foreach (i, arg; other)
			arr[i] = memberToBson(arg);
		query._query[name] = Bson(["$nin": Bson(arr)]);
		return *query;
	}

	alias notOneOf = noneOf;

	ref Query!Obj notInArray(V)(V[] array) if (isCompatible!V)
	{
		query._query[name] = Bson(["$nin": memberToBson(array)]);
		return *query;
	}

	ref Query!Obj exists(bool exists = true)
	{
		query._query[name] = Bson(["$exists": Bson(exists)]);
		return *query;
	}

	ref Query!Obj typeOf(Bson.Type type)
	{
		query._query[name] = Bson(["$type": Bson(cast(int) type)]);
		return *query;
	}

	ref Query!Obj typeOfAny(Bson.Type[] types...)
	{
		Bson[] arr = new Bson[types.length];
		foreach (i, type; types)
			arr[i] = Bson(cast(int) type);
		query._query[name] = Bson(["$type": Bson(arr)]);
		return *query;
	}

	ref Query!Obj typeOfAny(Bson.Type[] types)
	{
		query._query[name] = Bson(["$type": serializeToBson(types)]);
		return *query;
	}

	static if (is(T : U[], U))
	{
		ref Query!Obj containsAll(U[] values)
		{
			query._query[name] = Bson(["$all": serializeToBson(values)]);
			return *query;
		}

		alias all = containsAll;

		ref Query!Obj ofLength(size_t length)
		{
			query._query[name] = Bson(["$size": Bson(length)]);
			return *query;
		}

		alias size = ofLength;
	}

	static if (isIntegral!T)
	{
		ref Query!Obj bitsAllClear(T other)
		{
			query._query[name] = Bson(["$bitsAllClear": Bson(other)]);
			return *query;
		}

		ref Query!Obj bitsAllSet(T other)
		{
			query._query[name] = Bson(["$bitsAllSet": Bson(other)]);
			return *query;
		}

		ref Query!Obj bitsAnyClear(T other)
		{
			query._query[name] = Bson(["$bitsAnyClear": Bson(other)]);
			return *query;
		}

		ref Query!Obj bitsAnySet(T other)
		{
			query._query[name] = Bson(["$bitsAnySet": Bson(other)]);
			return *query;
		}
	}

	static if (isNumeric!T)
	{
		ref Query!Obj remainder(T divisor, T remainder)
		{
			query._query[name] = Bson(["$mod": Bson([Bson(divisor), Bson(remainder)])]);
			return *query;
		}
	}

	static if (isSomeString!T)
	{
		ref Query!Obj regex(string regex, string options = null)
		{
			if (options.length)
				query._query[name] = Bson([
						"$regex": Bson(regex),
						"$options": Bson(options)
						]);
			else
				query._query[name] = Bson(["$regex": Bson(regex)]);
			return *query;
		}
	}
}

private string generateMember(string member, string name)
{
	return `alias T_` ~ member ~ ` = typeof(__traits(getMember, T.init, "` ~ member ~ `"));

	FieldQuery!(T_` ~ member
		~ `, T) ` ~ member ~ `()
	{
		return FieldQuery!(T_` ~ member ~ `, T)(` ~ '`' ~ name ~ '`' ~ `, this);
	}

	typeof(this) ` ~ member
		~ `(T_` ~ member ~ ` equals)
	{
		return ` ~ member ~ `.equals(equals);
	}`;
}

private string generateMembers(T)(T obj)
{
	string ret;
	static foreach (memberName; getSerializableMembers!obj)
	{
		{
			string name = memberName;
			static if (hasUDA!((__traits(getMember, obj, memberName)), schemaName))
			{
				static assert(getUDAs!((__traits(getMember, obj, memberName)), schemaName)
						.length == 1, "Member '" ~ memberName ~ "' can only have one name!");
				name = getUDAs!((__traits(getMember, obj, memberName)), schemaName)[0].name;
			}
			ret ~= generateMember(memberName, name);
		}
	}
	return ret;
}

struct Query(T)
{
	Bson[string] _query;

	mixin(generateMembers!T(T.init));

	static Bson toBson(Query!T query)
	{
		return Bson(query._query);
	}
}

Query!T query(T)()
{
	return Query!T.init;
}

Query!T and(T)(Query!T[] exprs...)
{
	return Query!T(["$and": memberToBson(exprs)]);
}

Query!T not(T)(Query!T[] exprs)
{
	return Query!T(["$not": memberToBson(exprs)]);
}

Query!T nor(T)(Query!T[] exprs...)
{
	return Query!T(["$nor": memberToBson(exprs)]);
}

Query!T or(T)(Query!T[] exprs...)
{
	return Query!T(["$or": memberToBson(exprs)]);
}

unittest
{
	struct CoolData
	{
		int number;
		bool boolean;
		string[] array;
		@schemaName("t")
		string text;
	}

	assert(memberToBson(and(query!CoolData.number.gte(10),
			query!CoolData.number.lte(20), query!CoolData.boolean(true)
			.array.ofLength(10).text.regex("^yes"))).toString == Bson(
			[
				"$and": Bson([
					Bson(["number": Bson(["$gte": Bson(10)])]),
					Bson(["number": Bson(["$lte": Bson(20)])]),
					Bson([
						"array": Bson(["$size": Bson(10)]),
						"boolean": Bson(true),
						"t": Bson(["$regex": Bson("^yes")])
					]),
				])
			]).toString);
}
