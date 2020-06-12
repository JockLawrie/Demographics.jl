module Demographics

export Person, populate_contacts!, Household, School

using DataFrames
using Dates
using Distributions
using LightGraphs
using Logging
using Random


const contactids = fill(0, 100)   # Buffer for a mutable contact list
const households = Household[]    # households[i].adults[j] is the id of the jth adult in the ith household. Ditto children.
const workplaces = Vector{Int}[]  # workplaces[i][j] is the id of the jth worker in the ith workplace.
const communitycontacts = Int[]   # Contains person IDs. Community contacts can be derived for each person.
const socialcontacts    = Int[]   # Contains person IDs. Social contacts can be derived for each person.

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

Person(id, birthdate, sex, address, state) = Person(id, birthdaate, sex, address, state, 0, nothing, nothing, 0, 0)

"Age of person on dt, with unit one of :day, :month or :year."
function age(person::Person, dt::Date, unit::Symbol)
    birthdate = person.birthdate
    dt < birthdate && return nothing
    age = 0
    if unit == :day
        age = Dates.value(dt - birthdate)
    elseif unit == :month
        dt1 = birthdate
        while true  # Count months from birthdate
            dt1 += Month(1)
            if dt1 <= dt
                age += 1
            else
                break
            end
        end
    elseif unit == :year
        dt1 = birthdate
        while true  # Count years from birthdate
            dt1 += Year(1)
            if dt1 <= dt
                age += 1
            else
                break
            end
        end
    else
        error("Unknown time unit: $(unit)")
    end
    age
end

function populate_contacts!(agents, params, indata,
                            households, workplaces::Vector{Vector{Int}},
                            communitycontacts::Vector{Int}, socialcontacts::Vector{Int})
    age2first = construct_age2firstindex!(agents)  # agents[age2first[i]] is the first agent with age i
    @info "$(now()) Populating households with children"
    populate_households_with_children!(households, agents, age2first, indata["household_distribution"])
    @info "$(now()) Populating households without children"
    populate_households_without_children!(households, agents, indata["household_distribution"])
    @info "$(now()) Populating schools"
    populate_school_contacts!(agents, age2first, indata["primaryschool_distribution"], indata["secondaryschool_distribution"],
                              params[:ncontacts_s2s], params[:ncontacts_t2t], params[:ncontacts_t2s])
    @info "$(now()) Populating work places"
    populate_workplace_contacts!(workplaces, agents, params[:n_workplace_contacts], indata["workplace_distribution"])
    @info "$(now()) Populating communities"
    populate_community_contacts!(communitycontacts, agents)
    @info "$(now()) Populating social networks"
    populate_social_contacts!(socialcontacts, agents)
end

################################################################################
# Utils

function append_contact!(agentid, contactid::Int, contactlist::Vector{Int})
    agentid == contactid && return
    push!(contactlist, contactid)
end

"Randomly assign ncontacts to each agent whose id is a value of vertexid2agentid."
function assign_contacts_regulargraph!(agents, contactcategory::Symbol, ncontacts::Int, vertexid2agentid)
    nvertices = length(vertexid2agentid)
    ncontacts = adjust_ncontacts_for_regular_graph(nvertices, ncontacts)  # Ensure a regular graph can be constructed
    g = random_regular_graph(nvertices, ncontacts)  # nvertices each with ncontacts (edges to ncontacts other vertices)
    adjlist = g.fadjlist
    for (vertexid, agentid) in vertexid2agentid
        agent = agents[agentid]
        contactlist_vertex = adjlist[vertexid]  # Contact list as vertexid domain...convert to agentid domain
        contactlist_agent  = getproperty(agent, contactcategory)
        if isnothing(contactlist_agent)
            setproperty!(agent, contactcategory, Int[])
            contactlist_agent = getproperty(agent, contactcategory)
        end
        for vertexid in contactlist_vertex
            append_contact!(agentid, vertexid2agentid[vertexid], contactlist_agent)
        end
    end
end

"""
Require these conditions:
1. nvertices >= 1
2. ncontacts <= nvertices - 1
3. iseven(nvertices * ncontacts)

If required adjust ncontacts.
Return ncontacts.
"""
function adjust_ncontacts_for_regular_graph(nvertices, ncontacts)
    nvertices == 0 && error("The number of vertices must be at least 1")
    ncontacts = ncontacts > nvertices - 1 ? nvertices - 1 : ncontacts
    iseven(nvertices * ncontacts) ? ncontacts : ncontacts - 1
end

"""
Return the id of a random agent whose is unplaced and in the specified age range.
If one doesn't exist return a random id from unplaced_people.
"""
function sample_person(unplaced_people::Set{Int}, min_age, max_age, agents, age2first)
    i1 = age2first[min_age]
    i2 = age2first[max_age + 1] - 1
    s  = i1:i2      # Indices of people in the age range
    n  = length(s)  # Maximum number of random draws
    for i = 1:n
        id = rand(s)  # id is a random person in the age range
        id in unplaced_people && return id  # id is also an unplaced person
    end
    rand(unplaced_people)
end

"""
- Sort agents
- Rewrite their ids in order
- Return age2first, where agents[age2first[i]] is the first agent with age i
"""
function construct_age2firstindex!(agents)
    sort!(agents, by=(x) -> x.age)  # Sort from youngest to oldest
    age2first = Dict{Int, Int}()    # age => first index containing age
    current_age = -1
    for i = 1:length(agents)
        agent = agents[i]
        agent.id = i
        age = agent.age
        if age != current_age
            current_age = age
            age2first[current_age] = i
        end
    end
    age2first
end

################################################################################
# Households

struct Household
    max_nadults::Int
    max_nchildren::Int
    adults::Vector{Int}    # ids
    children::Vector{Int}  # ids

    function Household(max_nadults, max_nchildren, adults, children)
        length(adults)   > max_nadults        && error("Household has too many adults")
        length(children) > max_nchildren      && error("Household has too many children")
        max_nadults < 0                       && error("Household must have a non-negative number of adults")
        max_nchildren < 0                     && error("Household must have a non-negative number of children")
        max_nadults + max_nchildren == 0      && error("Household must have at least 1 resident")
        max_nadults == 0 && max_nchildren > 0 && error("Household with children must have at least 1 adult")
        new(max_nadults, max_nchildren, adults, children)
    end
end

Household(max_nadults, max_nchildren) = Household(max_nadults, max_nchildren, Int[], Int[])

isfull(hh::Household) = (length(hh.adults) == hh.max_nadults) && (length(hh.children) == hh.max_nchildren)

"Attempts to add an adult to the household. Returns true if successful."
function push_adult!(hh::Household, id)
    length(hh.adults) >= hh.max_nadults && return false  # Household is full. No success.
    push!(hh.adults, id)  # Add person to household
    true  # Success
end

"Attempts to add a child to the household. Returns true if successful."
function push_child!(hh::Household, id)
    length(hh.children) >= hh.max_nchildren && return false  # Household is full. No success.
    push!(hh.children, id)  # Add person to household
    true  # Success
end

################################################################################
# Households with children

"""
- Input data: 
  - d_nparents: Pr(nadults == k | nchildren > 0) = [0.26, 0.74]
  - d_nchildren: Pr(nchildren == k | nchildren > 0). E.g., [0.33, 0.4, 0.25, 0.01, 0.005, 0.005]
while n_unplaced_children > 0
    sample nchildren household from d_nchildren
    sample nadults from d_nparents
    construct household
    populate household
       - kids no more than (nchildren - 1) x 3 years apart
       - adults at least 20 years older than oldest child
    set household contacts
"""
function populate_households_with_children!(households, agents, age2first, household_distribution)
    family_household_distribution = construct_family_household_distribution(household_distribution)
    unplaced_children = Set(1:(age2first[18] - 1))
    unplaced_parents  = Set((age2first[20]):(age2first[55] - 1))  # Parents of children under 18 are adults aged between 20 and 54
    imax = length(unplaced_children)
    for i = 1:imax  # Cap the number of iterations by placing at least 1 child per iteration
        # Init household
        hh  = draw_household_with_children(unplaced_parents, unplaced_children, family_household_distribution)
        np  = hh.max_nadults
        nc  = hh.max_nchildren
        idx = size(households, 1) + 1  # households[idx] = new household

        # Select children
        min_age = 0   # Minimum age of the next selected child
        max_age = 17  # Maximum age of the next selected child
        age_youngest_child = 1000
        age_oldest_child   = -1
        for j = 1:nc
            childid = sample_person(unplaced_children, min_age, max_age, agents, age2first)
            pop!(unplaced_children, childid)
            push_child!(hh, childid)
            child = agents[childid]
            child.i_household = idx
            age = child.age
            age_youngest_child = age < age_youngest_child ? age : age_youngest_child
            age_oldest_child   = age > age_oldest_child   ? age : age_oldest_child
            min_age = max(0,  age_youngest_child - 3 * (nc - 1))
            max_age = min(17, age_oldest_child   + 3 * (nc - 1))
        end

        # Select parent/s
        min_parent_age = age_oldest_child + 20
        max_parent_age = age_oldest_child + 45
        for j = 1:np
            parentid = sample_person(unplaced_parents, min_parent_age, max_parent_age, agents, age2first)
            pop!(unplaced_parents, parentid)
            push_adult!(hh, parentid)
            agents[parentid].i_household = idx
        end
        push!(households, hh)

        # Stopping criteria
        isempty(unplaced_children) && break
        isempty(unplaced_parents)  && break
    end
end

function construct_family_household_distribution(household_distribution::DataFrame)
    result = DataFrame(nadults=Int[], nchildren=Int[], nhouseholds=Int[])
    family_household_distribution = view(household_distribution, household_distribution.nchildren .> 0, :)
    for subdata in groupby(family_household_distribution, [:nadults, :nchildren])
        row = (nadults=subdata[1, :nadults], nchildren=subdata[1, :nchildren], nhouseholds=sum(subdata.nhouseholds))
        push!(result, row)
    end
    result[!, :proportion] = result.nhouseholds ./ sum(result.nhouseholds)
    result
end

function draw_household_with_children(unplaced_parents, unplaced_children, family_household_distribution::DataFrame)
    n_unplaced_parents  = length(unplaced_parents)
    n_unplaced_children = length(unplaced_children)
    i         = rand(Categorical(family_household_distribution.proportion))
    nparents  = family_household_distribution[i, :nadults]
    nparents  = nparents > n_unplaced_parents ? n_unplaced_parents : nparents
    nchildren = family_household_distribution[i, :nchildren]
    nchildren = nchildren > n_unplaced_children ? n_unplaced_children : nchildren
    Household(nparents, nchildren)
end

################################################################################
# Households without children

"""
- Input data:
  - d_nadults_without_children: Pr(nadults == k | nchildren == 0). E.g., Proportional to [0.24, 0.27, 0.02, 0.02, 0.01, 0.01].
while n_unplaced_adults > 0
    sample 1 household from d_nadults_without_children
    construct household
    populate household
        - No constraints at the moment
    set household contacts
"""
function populate_households_without_children!(households::Vector{Household}, agents, household_distribution::DataFrame)
    nonfamily_household_distribution = construct_nonfamily_household_distribution(household_distribution)
    unplaced_adults = Set([agent.id for agent in agents if agent.i_household == 0])
    imax = length(unplaced_adults)
    for i = 1:imax  # Cap the number of iterations by placing at least 1 child per iteration
        # Init household
        hh  = draw_household_without_children(unplaced_adults, nonfamily_household_distribution)
        na  = hh.max_nadults
        idx = size(households, 1) + 1  # households[idx] = new household

        # Select adult/s
        for j = 1:na
            adultid = rand(unplaced_adults)
            pop!(unplaced_adults, adultid)
            push_adult!(hh, adultid)
            agents[adultid].i_household = idx
        end
        push!(households, hh)

        # Stopping criterion
        isempty(unplaced_adults) && break
    end
end

function construct_nonfamily_household_distribution(household_distribution::DataFrame)
    result = DataFrame(nadults=Int[], nchildren=Int[], nhouseholds=Int[])
    nonfamily_household_distribution = view(household_distribution, household_distribution.nchildren .== 0, :)
    for subdata in groupby(nonfamily_household_distribution, [:nadults, :nchildren])
        row = (nadults=subdata[1, :nadults], nchildren=subdata[1, :nchildren], nhouseholds=sum(subdata.nhouseholds))
        push!(result, row)
    end
    result[!, :proportion] = result.nhouseholds ./ sum(result.nhouseholds)
    result
end

function draw_household_without_children(unplaced_adults, nonfamily_household_distribution::DataFrame)
    n_unplaced_adults = length(unplaced_adults)
    i       = rand(Categorical(nonfamily_household_distribution.proportion))
    nadults = nonfamily_household_distribution[i, :nadults]
    nadults = nadults > n_unplaced_adults  ? n_unplaced_adults : nadults
    Household(nadults, 0)
end

################################################################################
# School contacts for teachers and people under 23

"""
Each teacher can contact N1 other teachers and N2 students from any age group.
Each student can contact N3 students in their age group.
"""
mutable struct School
    max_nteachers::Int
    max_nstudents_per_level::Int
    teachers::Vector{Int}
    age2students::Dict{Int, Vector{Int}}  # Classes: age => [childid1, ...]

    function School(max_nteachers, max_nstudents_per_level, teachers, age2students)
        max_nstudents_per_level < 1 && error("max_nstudents_per_level must be at least 1")
        new(max_nteachers, max_nstudents_per_level, teachers, age2students)
    end
end

function School(schooltype::Symbol,
                primaryschool_distribution::DataFrame, secondaryschool_distribution::DataFrame,
                d_nstudents_per_level_primary, d_nstudents_per_level_secondary)
    # Construct max_nstudents_per_level, age2students and the teacher-student ratio
    if schooltype == :childcare
        max_nstudents_per_level = 20
        teacher2student_ratio   = 1 / 15  # Need at least 1 teacher to 15 students
        age2students = Dict(age => Int[] for age = 0:4)
    elseif schooltype == :primary
        max_nstudents_per_level = draw_nstudents_per_level(primaryschool_distribution, d_nstudents_per_level_primary)
        teacher2student_ratio   = 1 / 15
        age2students = Dict(age => Int[] for age = 5:11)
    elseif schooltype == :secondary
        max_nstudents_per_level = draw_nstudents_per_level(secondaryschool_distribution, d_nstudents_per_level_secondary)
        teacher2student_ratio   = 1 / 15
        age2students = Dict(age => Int[] for age = 12:17)
    elseif schooltype == :tertiary
        teacher2student_ratio   = 1 / 40
        max_nstudents_per_level = 1000
        age2students = Dict(age => Int[] for age = 18:23)
    else
        error("Unknown school type")
    end

    # Calculate the number of required teachers
    nlevels       = length(age2students)
    max_nstudents = nlevels * max_nstudents_per_level
    max_nteachers = round(Int, teacher2student_ratio * max_nstudents)
    School(max_nteachers, max_nstudents_per_level, Int[], age2students)
end

function draw_nstudents_per_level(school_distribution::DataFrame, d_nstudents_per_level)
    i  = rand(d_nstudents_per_level)
    lb = school_distribution[i, :avg_year_level_size_lb]
    ub = school_distribution[i, :avg_year_level_size_ub]
    round(Int, 0.5 * (lb + ub))
end

function determine_schooltype(age::Int)
    age <= 4  && return :childcare
    age <= 11 && return :primary
    age <= 17 && return :secondary
    age <= 23 && return :tertiary
    error("Person with age $(age) cannot be assigned as a student to a school")
end

function isfull(school::School)
    length(school.teachers) >= school.max_nteachers && return true
    for (age, students) in school.age2students
        length(students) < school.max_nstudents_per_level && return false  # Room in this age group
    end
    true
end

function push_teacher!(school::School, id::Int)
    length(school.teachers) >= school.max_nteachers && return false  # Teacher positions are full. No success.
    push!(school.teachers, id)  # Add teacher to school
    true  # Success
end

function push_student!(school::School, id::Int, age::Int)
    v = school.age2students[age]
    length(v) >= school.max_nstudents_per_level && return false  # Child positions are full. No success.
    push!(v, id)  # Add teacher to school
    true  # Success
end

function populate_school_contacts!(agents, age2first, primaryschool_distribution::DataFrame, secondaryschool_distribution::DataFrame,
                                   ncontacts_s2s, ncontacts_t2t, ncontacts_t2s)
    d_nstudents_per_level_primary   = Categorical(primaryschool_distribution.proportion)
    d_nstudents_per_level_secondary = Categorical(secondaryschool_distribution.proportion)
    min_teacher_age   = 24
    max_teacher_age   = 65
    unplaced_students = Dict(age => Set(age2first[age]:(age2first[age+1] - 1)) for age = 0:23)
    unplaced_teachers = Set((age2first[min_teacher_age]):(age2first[max_teacher_age] - 1))
    imax              = sum([length(v) for (k, v) in unplaced_students])
    for i = 1:imax  # Cap the number of iterations by placing at least 1 child per iteration
        # Init school
        agentid = nothing
        for age = 0:23
            isempty(unplaced_students[age]) && continue
            agentid = rand(unplaced_students[age])
            break
        end
        isnothing(agentid) && break  # STOPPING CRITERION: There are no unplaced students remaining
        student    = agents[agentid]
        schooltype = determine_schooltype(student.age)
        school     = School(schooltype,
                            primaryschool_distribution, secondaryschool_distribution,
                            d_nstudents_per_level_primary, d_nstudents_per_level_secondary)

        # Fill student positions
        age2students = school.age2students
        for (age, students) in age2students
            n_available = school.max_nstudents_per_level - length(students)  # Number of available positions
            for j = 1:n_available
                isempty(unplaced_students[age]) && break
                studentid = sample_person(unplaced_students[age], age, age, agents, age2first)
                pop!(unplaced_students[age], studentid)
                push_student!(school, studentid, age)
            end
        end

        # Fill teacher positions
        n_available = school.max_nteachers - length(school.teachers)  # Number of available positions
        for j = 1:n_available
            isempty(unplaced_teachers) && break
            teacherid = sample_person(unplaced_teachers, min_teacher_age, max_teacher_age, agents, age2first)
            pop!(unplaced_teachers, teacherid)
            push_teacher!(school, teacherid)
        end

        # Set contact lists
        set_student_to_student_contacts!(agents, school, ncontacts_s2s)
        set_teacher_to_teacher_contacts!(agents, school, ncontacts_t2t)
        set_teacher_to_student_contacts!(agents, school, ncontacts_t2s)
    end
end

function set_student_to_student_contacts!(agents, school::School, ncontacts_s2s)
    age2students = school.age2students
    for (age, students) in age2students
        isempty(students) && continue
        nstudents        = length(students)
        vertexid2agentid = Dict(i => students[i] for i = 1:nstudents)
        assign_contacts_regulargraph!(agents, :school, min(Int(ncontacts_s2s), nstudents), vertexid2agentid)
    end
end

function set_teacher_to_teacher_contacts!(agents, school::School, ncontacts_t2t)
    teachers = school.teachers
    isempty(teachers) && return
    nteachers        = length(teachers)
    vertexid2agentid = Dict(i => teachers[i] for i = 1:nteachers)
    assign_contacts_regulargraph!(agents, :school, min(Int(ncontacts_t2t), nteachers), vertexid2agentid)
end

function set_teacher_to_student_contacts!(agents, school::School, ncontacts_t2s)
    # Construct a vector of studentids
    studentids = Int[]
    for (age, students) in school.age2students
        for studentid in students
            push!(studentids, studentid)
        end
    end
    nstudents = length(studentids)

    # For each teacher, cycle through the students until the teacher has enough contacts
    teachers = school.teachers
    ncontacts_t2s = Int(min(ncontacts_t2s, nstudents))  # Can't contact more students than are in the school
    idx = 0
    for teacherid in teachers
        teacher_contactlist = agents[teacherid].school
        for i = 1:ncontacts_t2s
            idx += 1
            idx  = idx > nstudents ? 1 : idx
            studentid = studentids[idx]
            student_contactlist = agents[studentid].school
            append_contact!(teacherid, studentid, teacher_contactlist)
            append_contact!(studentid, teacherid, student_contactlist)
        end
    end
end

################################################################################
# Workplace contacts

function populate_workplace_contacts!(workplaces::Vector{Vector{Int}}, agents, ncontacts, workplace_distribution::DataFrame)
    d_nworkers       = Categorical(workplace_distribution.proportion)  # Categories are: 0 employees, 1-4, 5-19, 20-199, 200+
    unplaced_workers = Set([agent.id for agent in agents if agent.age > 23 && isnothing(agent.school)])
    imax = length(unplaced_workers)
    for i = 1:imax
        isempty(unplaced_workers) && break
        nworkers  = draw_nworkers(workplace_distribution, d_nworkers)
        nworkers  = nworkers > length(unplaced_workers) ? length(unplaced_workers) : nworkers
        workplace = fill(0, nworkers)
        idx       = size(workplaces, 1) + 1  # workplaces[idx] = new workplace
        for j = 1:nworkers
            workerid = rand(unplaced_workers)
            pop!(unplaced_workers, workerid)
            workplace[j] = workerid
            agents[workerid].ij_workplace = (idx, j)
        end
        push!(workplaces, workplace)
    end
end

function draw_nworkers(workplace_distribution::DataFrame, d_workplace_size)
    i  = rand(d_workplace_size)
    lb = workplace_distribution[i, :nemployees_lb]
    ub = workplace_distribution[i, :nemployees_ub]
    rand(lb:ub) + 1
end

################################################################################
# Community contacts

function populate_community_contacts!(communitycontacts::Vector{Int}, agents)
    npeople = length(agents)
    for i = 1:npeople
        push!(communitycontacts, agents[i].id)
    end
    shuffle!(communitycontacts)
    for i = 1:npeople
        id = communitycontacts[i]
        agents[id].i_community = i
    end
end

################################################################################
# Social contacts

function populate_social_contacts!(socialcontacts::Vector{Int}, agents)
    npeople = length(agents)
    for i = 1:npeople
        push!(socialcontacts, agents[i].id)
    end
    shuffle!(socialcontacts)
    for i = 1:npeople
        id = socialcontacts[i]
        agents[id].i_social = i
    end
end

end
