module persons

export Person, age

using Dates

mutable struct Person{A, S}
    id::Int
    birthdate::Date
    sex::Char   # 'm', 'f', or 'o'
    address::A  # Any description of location that is fit for purpose. E.g., full address, postcode, suburb name, city, country, etc.
    state::S    # contains non-demographic variables whose values typically change over time. E.g., disease status, socioeconomic status, etc

    # Contact networks
    i_household::Int  # Person is in households[i_household].
    school::Union{Nothing, Vector{Int}}  # Child care, primary school, secondary school, university. Not empty for teachers and students.
    ij_workplace::Union{Nothing, Tuple{Int, Int}}  # Empty for children and teachers (whose workplace is school). person.id == workplaces[i][j].
    i_community::Int  # Shops, transport, pool, library, etc. communitycontacts[i_community] == person.id
    i_social::Int     # Family and/or friends outside the household. socialcontacts[i_social] == person.id
end

Person{A, S}(id, birthdate, sex, address, state) where {A, S} = Person(id, birthdate, sex, address::A, state::S, 0, nothing, nothing, 0, 0)

################################################################################
# Convenience functions

"Age of person on dt, with unit one of :day, :month or :year."
function age(person::Person{A, S}, dt::Date, unit::Symbol) where {A, S}
    birthdate = person.birthdate
    dt < birthdate && return nothing
    result = 0
    if unit == :day
        result = Dates.value(dt - birthdate)
    elseif unit == :month
        dt1 = birthdate
        while true  # Count months from birthdate
            dt1 += Month(1)
            if dt1 <= dt
                result += 1
            else
                break
            end
        end
    elseif unit == :year
        dt1 = birthdate
        while true  # Count years from birthdate
            dt1 += Year(1)
            if dt1 <= dt
                result += 1
            else
                break
            end
        end
    else
        error("Unknown time unit: $(unit)")
    end
    result
end

"""
- Sort people
- Rewrite their ids in order
- Return age2first, where people[age2first[i]] is the first agent with age i
"""
function construct_age2firstindex!(people::Vector{Person{A, S}}, dt) where {A, S}
    sort!(people, by=(x) -> x.birthdate, rev=true)  # Sort from youngest to oldest
    age2first   = Dict{Int, Int}()  # age => first index containing age
    current_age = -1
    for i = 1:length(people)
        person    = people[i]
        person.id = i
        age_years = age(person, dt, :year)
        if age_years != current_age
            current_age = age_years
            age2first[current_age] = i
        end
    end
    age2first
end

function construct_age2index_by_SA2(people::Vector{Person{A,S}},dt,SA2_list,first::Bool) where {A,S}
    age2idx = Dict{Int,Dict}()  # SA2,age => first or last index containing age for the given SA2
    def_val = -2 # Set deault to unusable index
    if first
        def_val = -1 # Set default such that Set(age2first[i]:age2last[i]) will return empty if no one exists
    end
    for SA2 in SA2_list
        age2idx[SA2] = Dict()
        for i =0:116
            age2idx[SA2][i] = def_val
        end
    end

    current_age = -1
    current_SA2 = 0
    for i = 1:length(people)
        if first == true
            idx = i
        else
            idx = length(people)-i+1
        end
        person    = people[idx]
        age_years = age(person, dt, :year)
        if age_years != current_age || person.address != current_SA2 #account for sometimes missing SA2/age
            age2idx[person.address][age_years] = idx
            if age_years!=current_age
                current_age = age_years
            end
            current_SA2 = person.address
        end
    end
    age2idx
end

end
