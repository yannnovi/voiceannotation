// Minimal JSON reader/writer.
//
// Vosk hands its results back as JSON strings, and the transcript is exported
// as JSON, so the project needs a parser -- but only a very small one. This is
// a self-contained recursive-descent parser with no third-party dependency,
// which keeps the build identical on Windows, Linux and macOS.
#ifndef VA_UTIL_JSON_H
#define VA_UTIL_JSON_H

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace va {

class Json {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    Json() = default;
    static Json parse(const std::string& text, std::string* error = nullptr);

    Type type() const { return type_; }
    bool isNull() const { return type_ == Type::Null; }
    bool isArray() const { return type_ == Type::Array; }
    bool isObject() const { return type_ == Type::Object; }

    // Lookups never throw: a missing key or a wrong type yields the fallback.
    const Json& operator[](const std::string& key) const;
    const Json& operator[](std::size_t index) const;
    std::size_t size() const;
    bool has(const std::string& key) const;

    double asDouble(double fallback = 0.0) const;
    int asInt(int fallback = 0) const;
    bool asBool(bool fallback = false) const;
    std::string asString(const std::string& fallback = std::string()) const;

    const std::vector<Json>& items() const { return array_; }
    const std::map<std::string, Json>& fields() const { return object_; }

    // --- writing ---------------------------------------------------------
    static std::string escape(const std::string& s);
    // Formats a double without a trailing ".0"-style noise and without the
    // locale-dependent behaviour of printf("%f").
    static std::string number(double v, int decimals = 3);

private:
    Type type_ = Type::Null;
    bool bool_ = false;
    double number_ = 0.0;
    std::string string_;
    std::vector<Json> array_;
    std::map<std::string, Json> object_;

    friend class JsonParser;
    static const Json& none();
};

}  // namespace va

#endif  // VA_UTIL_JSON_H
